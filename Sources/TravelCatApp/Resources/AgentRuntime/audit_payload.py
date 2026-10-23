"""Bounded response audit text and provider-reported token accounting."""
import codecs
import json
import re

CHUNK_BYTES = 16 * 1024
MAX_USAGE_BYTES = 32 * 1024 * 1024


def _key_variants(key):
    if not key:
        return []
    return sorted({key, json.dumps(key, ensure_ascii=False)[1:-1],
                   json.dumps(key, ensure_ascii=True)[1:-1]}, key=len, reverse=True)


def sanitize(text, key):
    variants = _key_variants(key)
    return re.sub('|'.join(re.escape(value) for value in variants),
                  lambda match: '[REDACTED]', text) if variants else text


def _sanitize_value(value, key):
    if isinstance(value, str):
        return sanitize(value, key)
    if isinstance(value, list):
        return [_sanitize_value(item, key) for item in value]
    if isinstance(value, dict):
        return {sanitize(name, key): _sanitize_value(item, key) for name, item in value.items()}
    return value


def _chunks(text):
    # Slice on characters, then shorten to a UTF-8 boundary when needed.
    result = []
    while text:
        candidate = text[:CHUNK_BYTES]
        encoded = candidate.encode('utf-8')
        if len(encoded) > CHUNK_BYTES:
            candidate = encoded[:CHUNK_BYTES].decode('utf-8', errors='ignore')
        result.append(candidate)
        text = text[len(candidate):]
    return result


class ResponseAudit:
    def __init__(self, key):
        self.key = key or ''
        self.variants = _key_variants(self.key)
        self.keep = max((len(value) - 1 for value in self.variants), default=0)
        self.pattern = re.compile('|'.join(re.escape(value) for value in self.variants)) if self.variants else None
        self.decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
        self.pending = ''
        self.raw = bytearray()
        self.overflow = False
        self.finished = False

    def feed(self, data):
        if self.finished:
            raise ValueError('Response audit already finished')
        if not self.overflow:
            if len(self.raw) + len(data) <= MAX_USAGE_BYTES:
                self.raw.extend(data)
            else:
                self.raw.clear()
                self.overflow = True
        self.pending += self.decoder.decode(data)
        cut = max(0, len(self.pending) - self.keep)
        if self.pattern:
            for match in self.pattern.finditer(self.pending):
                if match.start() >= cut:
                    break
                if match.end() > cut:
                    cut = match.start()
                    break
        ready, self.pending = self.pending[:cut], self.pending[cut:]
        return _chunks(sanitize(ready, self.key))

    def finish(self):
        if self.finished:
            return []
        self.finished = True
        ready = self.pending + self.decoder.decode(b'', final=True)
        self.pending = ''
        return _chunks(sanitize(ready, self.key))

    def semantic_secret_detected(self):
        """Check decoded JSON/SSE string streams before releasing any response body.

        Array indices are deliberately coalesced: ambiguity fails conservatively.
        This protects exact configured-key/JSON escaping, not arbitrary encodings.
        """
        if self.overflow:
            return True
        if not self.key:
            return False
        text = sanitize(bytes(self.raw).decode('utf-8', errors='replace'), self.key)
        tails = {}
        def inspect(value, path=()):
            if isinstance(value, str):
                joined = tails.get(path, '') + value
                if sanitize(joined, self.key) != joined:
                    return True
                if len(tails) >= 4096 and path not in tails:
                    return True
                tails[path] = joined[-(self.keep + 1):]
            elif isinstance(value, dict):
                for name, item in value.items():
                    if inspect(item, path + (name,)):
                        return True
            elif isinstance(value, list):
                for item in value:
                    if inspect(item, path + ('[]',)):
                        return True
            return False
        try:
            try:
                return inspect(json.loads(text))
            except ValueError:
                for event in text.replace('\r\n', '\n').replace('\r', '\n').split('\n\n'):
                    data = '\n'.join(line[5:].lstrip(' ') for line in event.split('\n') if line.startswith('data:'))
                    if not data or data == '[DONE]':
                        continue
                    try:
                        document = json.loads(data)
                    except ValueError:
                        continue
                    if inspect(document):
                        return True
        except RecursionError:
            return True
        return False

    def usage(self):
        result = dict(totalInput=None, output=None, cacheRead=None, cacheWrite=None,
                      source='unknown', rawUsage=[])
        if self.overflow:
            return result
        text = bytes(self.raw).decode('utf-8', errors='replace')
        documents = []
        try:
            documents.append(json.loads(text))
        except (ValueError, RecursionError):
            for event in text.replace('\r\n', '\n').replace('\r', '\n').split('\n\n'):
                data = '\n'.join(line[5:].lstrip(' ') for line in event.split('\n') if line.startswith('data:'))
                try:
                    documents.append(json.loads(data))
                except (ValueError, RecursionError):
                    pass
        raw_bytes = 2  # JSON array delimiters.
        for document in documents:
            if not isinstance(document, dict):
                continue
            objects = [document] + [document[k] for k in ('message', 'response') if isinstance(document.get(k), dict)]
            for obj in objects:
                raw = obj.get('usage')
                if not isinstance(raw, dict):
                    continue
                # Sanitization includes raw provider metadata and dictionary keys.
                try:
                    # Reject oversized metadata before traversing it for redaction.
                    encoded = json.dumps(raw)
                    if len(encoded) > 65536:
                        raise ValueError('raw usage limit')
                    clean = _sanitize_value(raw, self.key)
                    size = len(json.dumps(clean).encode('utf-8')) + (2 if result['rawUsage'] else 0)
                    if raw_bytes + size > 65536:
                        raise ValueError('raw usage limit')
                    result['rawUsage'].append(clean)
                    raw_bytes += size
                except (ValueError, RecursionError):
                    result['rawUsageTruncated'] = True
                def count(name, source=raw):
                    value = source.get(name)
                    return value if type(value) is int and value >= 0 else None
                incoming = count('prompt_tokens')
                if incoming is None:
                    incoming = count('input_tokens')
                    if incoming is not None and any(k in raw for k in ('cache_read_input_tokens', 'cache_creation_input_tokens')):
                        incoming += (count('cache_read_input_tokens') or 0) + (count('cache_creation_input_tokens') or 0)
                output = count('completion_tokens')
                if output is None:
                    output = count('output_tokens')
                cached = count('cache_read_input_tokens')
                for name in ('prompt_tokens_details', 'input_tokens_details'):
                    if cached is None and isinstance(raw.get(name), dict):
                        cached = count('cached_tokens', raw[name])
                for name, value in [('totalInput', incoming), ('output', output), ('cacheRead', cached), ('cacheWrite', count('cache_creation_input_tokens'))]:
                    if value is not None:
                        result[name] = value
                        result['source'] = 'reported'
        return result
