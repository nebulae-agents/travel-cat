import json
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Sources/TravelCatApp/Resources/AgentRuntime'))
import audit_payload

class AuditPayloadTests(unittest.TestCase):
    def collect(self, payload, key='secret', size=1):
        audit = audit_payload.ResponseAudit(key)
        chunks = []
        for offset in range(0, len(payload), size):
            chunks += audit.feed(payload[offset:offset + size])
        chunks += audit.finish()
        return ''.join(chunks), audit.usage(), chunks

    def test_redacts_key_at_every_boundary_and_preserves_unicode(self):
        payload = '猫 secretsecret 旅行'.encode()
        for size in range(1, len(payload)):
            text, _, _ = self.collect(payload, size=size)
            self.assertEqual(text, '猫 [REDACTED][REDACTED] 旅行')
        self.assertEqual(audit_payload.sanitize('secret!', 'secret'), '[REDACTED]!')

    def test_chunks_are_bounded_utf8(self):
        text, _, chunks = self.collect(('猫' * 20000).encode(), key='', size=100000)
        self.assertEqual(text, '猫' * 20000)
        self.assertTrue(all(len(chunk.encode()) <= 16384 for chunk in chunks))

    def test_json_openai_usage(self):
        raw = {'prompt_tokens': 20, 'completion_tokens': 5, 'prompt_tokens_details': {'cached_tokens': 8}}
        _, usage, _ = self.collect(json.dumps({'usage': raw}).encode())
        self.assertEqual(usage, dict(totalInput=20, output=5, cacheRead=8, cacheWrite=None, source='reported', rawUsage=[raw]))

    def test_sse_anthropic_cumulative_usage(self):
        events = [{'message': {'usage': {'input_tokens': 10, 'cache_read_input_tokens': 6, 'cache_creation_input_tokens': 2, 'output_tokens': 1}}}, {'usage': {'output_tokens': 9}}]
        payload = ''.join('data: ' + json.dumps(event) + '\r\n\r\n' for event in events).encode()
        _, usage, _ = self.collect(payload, size=7)
        self.assertEqual([usage[k] for k in ['totalInput','output','cacheRead','cacheWrite']], [18,9,6,2])
        self.assertEqual(len(usage['rawUsage']), 2)

    def test_responses_api_and_unknown_usage(self):
        _, usage, _ = self.collect(json.dumps({'response': {'usage': {'input_tokens': 12, 'output_tokens': 3, 'input_tokens_details': {'cached_tokens': 4}}}}).encode())
        self.assertEqual(usage['totalInput'], 12)
        self.assertEqual(usage['cacheRead'], 4)
        _, unknown, _ = self.collect(b'not json')
        self.assertEqual(unknown['source'], 'unknown')
        self.assertIsNone(unknown['totalInput'])

    def test_raw_usage_redacts_escaped_key(self):
        key = 'a\"b'
        _, usage, _ = self.collect(json.dumps({'usage': {'note': key}}).encode(), key=key)
        self.assertEqual(usage['rawUsage'][0]['note'], '[REDACTED]')

    def test_invalid_usage_is_unknown_and_raw_is_redacted(self):
        _, usage, _ = self.collect(b'{"usage":{"input_tokens":true,"output_tokens":-1,"key":"secret"}}')
        self.assertEqual(usage['source'], 'unknown')
        self.assertNotIn('secret', json.dumps(usage))


class AuditPayloadHardeningTests(unittest.TestCase):
    def test_escaped_secrets_split_at_each_byte(self):
        key = '猫"\\key'
        for variant in (key, json.dumps(key, ensure_ascii=False)[1:-1], json.dumps(key, ensure_ascii=True)[1:-1]):
            audit = audit_payload.ResponseAudit(key)
            chunks = []
            for byte in ('prefix ' + variant + ' suffix').encode():
                chunks += audit.feed(bytes([byte]))
            chunks += audit.finish()
            self.assertEqual(''.join(chunks), 'prefix [REDACTED] suffix')

    def test_large_raw_usage_retains_counts_with_bounded_metadata(self):
        audit = audit_payload.ResponseAudit('secret')
        audit.feed(json.dumps({'usage': {'input_tokens': 12, 'output_tokens': 4, 'details': 'x' * 100000}}).encode())
        audit.finish()
        usage = audit.usage()
        self.assertEqual(usage['totalInput'], 12)
        self.assertEqual(usage['output'], 4)
        self.assertTrue(usage['rawUsageTruncated'])
        self.assertLessEqual(len(json.dumps(usage['rawUsage']).encode()), 65536)

if __name__ == '__main__': unittest.main()
