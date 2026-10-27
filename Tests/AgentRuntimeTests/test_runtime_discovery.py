import json
import os
import pathlib
import tempfile
import unittest
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "Sources/TravelCatApp/Resources/AgentRuntime"))
import runtime_discovery


DIGEST = 'a' * 64


class LocalDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.home = self.root / 'home'
        self.home.mkdir()
        self.env = {'PATH': str(self.bin), 'HOME': str(self.home)}
        self.calls = []

    def executable(self, name):
        path = self.bin / name
        path.write_text('not an executable script')
        path.chmod(0o755)
        return str(path)

    def test_installed_tools_and_current_user_processes_are_distinct(self):
        codex = self.executable('codex')
        claude = self.executable('claude')

        def run(args, timeout, limit):
            self.calls.append(tuple(args))
            if args[0] == '/bin/ps':
                self.assertIn('-u', args)
                self.assertIn('comm=', args)
                return '/opt/homebrew/bin/codex\n/usr/local/bin/claude\n/usr/local/bin/claude\n'
            if args[:3] == ['docker', 'context', 'ls']:
                return ''
            self.fail(f'unexpected command: {args}')

        found = runtime_discovery.scan_local(self.env, run, uid=501)
        self.assertEqual([(x['kind'], x['path'], x['running']) for x in found['tools']],
                         [('codex', codex, 1), ('claude', claude, 2)])
        self.assertEqual(found['images'], [])
        self.assertFalse(any(call[0] in (codex, claude) for call in self.calls))
        self.assertFalse(any(call[0] in ('ssh', 'sh', 'bash') for call in self.calls))

    def test_running_process_is_visible_even_when_cli_path_is_missing(self):
        def run(args, timeout, limit):
            if args[0] == '/bin/ps': return '/tmp/old-location/dsh\n'
            return ''
        found = runtime_discovery.scan_local(self.env, run, uid=501)
        self.assertEqual(found['tools'], [{'kind': 'dsh', 'path': '', 'running': 1}])

    def test_only_unix_context_is_connected_and_images_are_pinned(self):
        contexts = '\n'.join(json.dumps(row) for row in [
            {'Name': 'remote', 'DockerEndpoint': 'ssh://ops@example.com'},
            {'Name': 'colima-safe', 'DockerEndpoint': 'unix:///tmp/docker.sock'},
        ])
        image = 'localhost:5000/codex-acp@sha256:' + DIGEST

        def run(args, timeout, limit):
            self.calls.append(tuple(args))
            if args[0] == '/bin/ps': return ''
            if args[:3] == ['docker', 'context', 'ls']:
                return contexts
            self.assertEqual(args[:3], ['docker', '--host', 'unix:///tmp/docker.sock'])
            if args[3] == 'info': return '29.2.1\n'
            if args[3:5] == ['image', 'ls']:
                return f'{image}\n{image}\nother:latest@<none>\n'
            if args[3] == 'ps':
                return json.dumps({'ID': 'abcdef123456', 'Names': 'codex-worker', 'Image': image, 'Status': 'Up 2 minutes'}) + '\n'
            self.fail(f'unexpected command: {args}')

        found = runtime_discovery.scan_local(self.env, run, uid=501)
        self.assertEqual(found['images'], [{'context': 'colima-safe', 'ref': image}])
        self.assertEqual(found['containers'][0]['name'], 'codex-worker')
        self.assertEqual(found['containers'][0]['context'], 'colima-safe')
        self.assertEqual(found['contexts'][0]['name'], 'remote')
        self.assertFalse(found['contexts'][0]['local'])
        self.assertTrue(found['contexts'][1]['available'])
        self.assertFalse(any('ssh://ops@example.com' in str(call) for call in self.calls if call[:3] != ('docker', 'context', 'ls')))

    def test_unavailable_context_does_not_hide_other_results(self):
        contexts = '\n'.join(json.dumps({'Name': name, 'DockerEndpoint': 'unix:///tmp/' + name + '.sock'})
                             for name in ('broken', 'working'))

        def run(args, timeout, limit):
            if args[0] == '/bin/ps': return ''
            if args[:3] == ['docker', 'context', 'ls']: return contexts
            if args[2].endswith('/broken.sock'): raise runtime_discovery.DiscoveryFailure('private engine error')
            if args[3] == 'info': return '29.2.1'
            return ''

        found = runtime_discovery.scan_local(self.env, run, uid=501)
        self.assertEqual([(x['name'], x['available']) for x in found['contexts']], [('broken', False), ('working', True)])
        self.assertNotIn('private engine error', str(found))

    def test_scan_has_a_global_deadline_across_many_local_contexts(self):
        from unittest.mock import patch
        now = [0]
        calls = []
        contexts = '\n'.join(json.dumps({'Name': name, 'DockerEndpoint': 'unix:///tmp/' + name + '.sock'})
                             for name in ('first', 'second', 'third'))
        def run(args, timeout, limit):
            calls.append(tuple(args))
            if args[0] == '/bin/ps': return ''
            if args[:3] == ['docker', 'context', 'ls']: return contexts
            if args[3] == 'info':
                now[0] = 80
                return '29.2.1'
            self.fail('deadline should skip later Docker commands')
        with patch.object(runtime_discovery.time, 'monotonic', side_effect=lambda: now[0]):
            found = runtime_discovery.scan_local(self.env, run, uid=501)
        self.assertEqual([x['available'] for x in found['contexts']], [True, False, False])
        self.assertEqual(sum(call[3] == 'info' for call in calls if len(call) > 3), 1)

    def test_invalid_context_name_never_becomes_an_argv(self):
        def run(args, timeout, limit):
            self.calls.append(tuple(args))
            if args[0] == '/bin/ps': return ''
            return json.dumps({'Name': '--host=evil', 'DockerEndpoint': 'unix:///tmp/docker.sock'}) + '\n'

        found = runtime_discovery.scan_local(self.env, run, uid=501)
        self.assertEqual(found['contexts'], [])
        self.assertFalse(any('--host=evil' in call for call in self.calls))
