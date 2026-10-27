"""Bounded, read-only discovery of this user's local agent tools and Docker engines."""

import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import time


class DiscoveryFailure(Exception):
    pass


_TOOL_NAMES = ('codex', 'claude', 'dsh')
_CONTEXT_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z')
_PINNED_IMAGE = re.compile(r'[^\s@]+@sha256:[0-9a-f]{64}\Z')
_MAX_ROWS = 200
_MAX_CONTEXTS = 16
_MAX_OUTPUT = 1024 * 1024


def _run(args, timeout, limit):
    """Run fixed read-only commands without a shell, bounding time and output."""
    process = None
    selector = selectors.DefaultSelector()
    try:
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL,
                                   env={key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL')
                                        if key in os.environ})
        selector.register(process.stdout, selectors.EVENT_READ)
        end = time.monotonic() + timeout
        chunks = []
        size = 0
        while selector.get_map():
            remaining = end - time.monotonic()
            if remaining <= 0:
                raise DiscoveryFailure('local scan timed out')
            if not selector.select(remaining):
                raise DiscoveryFailure('local scan timed out')
            chunk = os.read(process.stdout.fileno(), min(65536, limit - size + 1))
            if not chunk:
                selector.unregister(process.stdout)
                break
            size += len(chunk)
            if size > limit:
                raise DiscoveryFailure('local scan output too large')
            chunks.append(chunk)
        if process.wait(timeout=max(0.1, end - time.monotonic())):
            raise DiscoveryFailure('local scan command failed')
        return b''.join(chunks).decode('utf-8', errors='replace')
    except (OSError, subprocess.TimeoutExpired):
        raise DiscoveryFailure('local scan unavailable') from None
    finally:
        selector.close()
        if process is not None:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()


def _lines(text):
    return text.splitlines()[:_MAX_ROWS]


def _find_tools(environ, running):
    home = Path(environ.get('HOME', ''))
    search = [Path(path) for path in environ.get('PATH', '').split(os.pathsep) if path]
    if home.is_absolute():
        search.extend((home / '.local/bin', home / '.codex/bin', home / '.claude/bin'))
    tools = []
    for name in _TOOL_NAMES:
        found_path = ''
        for directory in search[:64]:
            candidate = directory / name
            try:
                if candidate.is_file() and os.access(candidate, os.X_OK):
                    found_path = str(candidate)
                    break
            except OSError:
                continue
        if found_path or running.get(name, 0):
            tools.append({'kind': name, 'path': found_path, 'running': running.get(name, 0)})
    return tools


def _running_tools(runner, uid):
    try:
        output = runner(['/bin/ps', '-u', str(uid), '-o', 'comm='], 5, 65536)
    except (DiscoveryFailure, OSError):
        return {}
    counts = {}
    for command in _lines(output):
        name = Path(command.strip()).name
        if name in _TOOL_NAMES:
            counts[name] = counts.get(name, 0) + 1
    return counts


def _context_rows(text):
    for line in _lines(text):
        try:
            value = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(value, dict):
            continue
        name, endpoint = value.get('Name'), value.get('DockerEndpoint')
        if not isinstance(name, str) or not _CONTEXT_NAME.fullmatch(name):
            continue
        if not isinstance(endpoint, str) or len(endpoint) > 512:
            continue
        local = endpoint.startswith('unix:///') and '\n' not in endpoint and '\x00' not in endpoint
        yield name, endpoint, local


def _docker_contexts(runner):
    try:
        output = runner(['docker', 'context', 'ls', '--format', '{{json .}}'], 8, _MAX_OUTPUT)
    except (DiscoveryFailure, OSError):
        return []
    return list(_context_rows(output))


def _pinned_images(text):
    for line in _lines(text):
        ref = line.strip()
        if _PINNED_IMAGE.fullmatch(ref):
            yield ref


def _containers(text, context):
    for line in _lines(text):
        try:
            value = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(value, dict):
            continue
        identifier, name, image = value.get('ID'), value.get('Names'), value.get('Image')
        if not all(isinstance(x, str) for x in (identifier, name, image)):
            continue
        if not re.fullmatch(r'[0-9a-fA-F]{12,64}', identifier):
            continue
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', name):
            continue
        if not _PINNED_IMAGE.fullmatch(image):
            continue
        if not any(token in (name + ' ' + image).lower() for token in _TOOL_NAMES):
            continue
        yield {'context': context, 'id': identifier[:12], 'name': name,
               'image': image, 'state': 'running'}


def scan_local(environ=None, runner=None, uid=None):
    """Inventory fixed local tools and Unix-socket Docker contexts; never execute an agent."""
    environ = os.environ if environ is None else environ
    runner = _run if runner is None else runner
    uid = os.getuid() if uid is None else uid
    deadline = time.monotonic() + 75
    def bounded(args, timeout, limit):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise DiscoveryFailure('local scan deadline reached')
        return runner(args, min(timeout, max(0.1, remaining)), limit)
    found = {'tools': _find_tools(environ, _running_tools(runner, uid)),
             'contexts': [], 'images': [], 'containers': []}
    seen_images = set()
    for name, endpoint, local in _docker_contexts(runner)[:_MAX_CONTEXTS]:
        context = {'name': name, 'local': local, 'available': False}
        found['contexts'].append(context)
        if not local:
            continue
        prefix = ['docker', '--host', endpoint]
        try:
            bounded([*prefix, 'info', '--format', '{{.ServerVersion}}'], 8, 4096)
            context['available'] = True
        except (DiscoveryFailure, OSError):
            continue
        try:
            output = bounded([*prefix, 'image', 'ls', '--digests', '--format', '{{.Repository}}@{{.Digest}}'],
                            8, _MAX_OUTPUT)
            for image in _pinned_images(output):
                key = (name, image)
                if key not in seen_images:
                    seen_images.add(key)
                    found['images'].append({'context': name, 'ref': image})
        except (DiscoveryFailure, OSError):
            pass
        try:
            output = bounded([*prefix, 'ps', '--format', '{{json .}}'], 8, _MAX_OUTPUT)
            found['containers'].extend(_containers(output, name))
        except (DiscoveryFailure, OSError):
            pass
    return found
