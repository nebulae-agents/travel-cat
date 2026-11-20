import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Runtime'))
import agentxd_audit


class TestAuditBridge(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.helper = self.root / 'helper'

    def bridge(self, source):
        self.helper.write_text('#!' + sys.executable + '\n' + source)
        self.helper.chmod(0o700)
        self.assertTrue(hasattr(agentxd_audit, 'SwiftAudit'), 'missing bounded Swift helper bridge')
        return agentxd_audit.SwiftAudit(self.root, 'pilot', self.helper)

    def test_private_stdin_request_and_fixed_arguments(self):
        bridge = self.bridge("import sys,json\na=json.load(sys.stdin)\nassert sys.argv[1:]==['--agentx-audit-helper','--root'," + repr(str(self.root)) + ",'--app','pilot']\nprint(json.dumps({'ok':True,'records': [] if a['op']=='records' else 0}))\n")
        bridge.append({'eventId': 'fixture'})
        self.assertEqual(bridge.records('run'), [])
        self.assertEqual(bridge.verify(), 0)

    def test_helper_failure_does_not_expose_stderr(self):
        bridge = self.bridge("import sys\nprint('PRIVATE',file=sys.stderr)\nsys.exit(1)\n")
        with self.assertRaisesRegex(ValueError, '^audit helper unavailable$'):
            bridge.verify()

    def test_oversized_output_and_hanging_helper_are_bounded(self):
        bridge = self.bridge("import sys,time\nsys.stdout.write('x'*10000);sys.stdout.flush();time.sleep(10)\n")
        bridge.max_output = 100
        bridge.timeout = .2
        with self.assertRaises(ValueError):
            bridge.verify()

    def test_invalid_response_and_symlink_helper_are_rejected(self):
        bridge = self.bridge("print('{\"ok\":false}')\n")
        with self.assertRaises(ValueError):
            bridge.verify()
        link = self.root / 'linked'
        link.symlink_to(self.helper)
        with self.assertRaises(ValueError):
            agentxd_audit.SwiftAudit(self.root, 'pilot', link)

    def test_silent_helper_times_out(self):
        bridge = self.bridge("import time\ntime.sleep(10)\n")
        bridge.timeout = .1
        with self.assertRaisesRegex(ValueError, '^audit helper unavailable$'):
            bridge.verify()

    def test_service_resolves_helper_from_bundle_and_cleans_endpoint(self):
        import plistlib
        from agentxd import serve
        app = self.root / 'apps/pilot'
        (app / 'runs').mkdir(parents=True)
        (app / 'app.yaml').touch()
        (self.root / '.agentxd-pilot.json').write_text(json.dumps(dict(root=str(self.root), appID='pilot')))
        bundle = self.root / 'Fixture.app'
        binaries = bundle / 'Contents/MacOS'
        binaries.mkdir(parents=True)
        self.bridge("import json,sys\nprint('{\"ok\":true,\"ready\":true}',flush=True)\nfor line in sys.stdin:\n json.loads(line);print('{\"ok\":true,\"records\":0}',flush=True)\n")
        self.helper.rename(binaries / 'Fixture')
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable='Fixture')))
        class Done(Exception):
            pass
        children = []
        def ready(store):
            children.append(store.audit.process)
            self.assertEqual(store.audit.verify(), 0)
            self.assertTrue((self.root / '.agentxd-endpoint.json').is_file())
            raise Done()
        with self.assertRaises(Done):
            serve(self.root, on_ready=ready, pi_bundle=bundle)
        self.assertFalse((self.root / '.agentxd-endpoint.json').exists())
        self.assertEqual(len(children), 1)
        self.assertIsNotNone(children[0].poll())


class TestAuditSession(unittest.TestCase):
    setUp = TestAuditBridge.setUp
    def session(self, source):
        self.helper.write_text('#!' + sys.executable + '\n' + source)
        self.helper.chmod(0o700)
        return agentxd_audit.SwiftAudit(self.root, 'pilot', self.helper, persistent=True)

    def test_reuses_process_and_reaps_it_on_close(self):
        audit = self.session("import sys,json\nprint('{\"ok\":true,\"ready\":true}',flush=True)\nfor line in sys.stdin:\n json.loads(line);print('{\"ok\":true,\"records\":0}',flush=True)\n")
        self.addCleanup(audit.close)
        child = audit.process
        for _ in range(5): self.assertEqual(audit.verify(), 0)
        self.assertIs(audit.process, child)
        audit.close()
        self.assertIsNotNone(child.poll())
        with self.assertRaisesRegex(ValueError, '^audit helper unavailable$'): audit.verify()

    def test_timeout_seals_session_without_respawning(self):
        audit = self.session("import sys,time\nprint('{\"ok\":true,\"ready\":true}',flush=True)\nfor line in sys.stdin: time.sleep(10)\n")
        self.addCleanup(audit.close)
        child = audit.process
        audit.timeout = .1
        with self.assertRaisesRegex(ValueError, '^audit helper unavailable$'): audit.verify()
        self.assertIsNotNone(child.poll())
        with self.assertRaises(ValueError): audit.verify()
        self.assertIs(audit.process, child)

    def test_output_limit_and_private_errors_fail_closed(self):
        audit = self.session("import sys\nprint('{\"ok\":true,\"ready\":true}',flush=True)\nfor line in sys.stdin: print('private-canary'*100,flush=True)\n")
        self.addCleanup(audit.close)
        audit.max_output = 100
        with self.assertRaisesRegex(ValueError, '^audit helper unavailable$'): audit.verify()
        self.assertIsNotNone(audit.process.poll())

    def test_concurrent_calls_are_serialized(self):
        from concurrent.futures import ThreadPoolExecutor
        audit = self.session("import sys,json\nprint('{\"ok\":true,\"ready\":true}',flush=True)\nn=0\nfor line in sys.stdin:\n json.loads(line);n+=1;print(json.dumps({'ok':True,'records':n}),flush=True)\n")
        self.addCleanup(audit.close)
        with ThreadPoolExecutor(max_workers=4) as pool:
            self.assertEqual(sorted(pool.map(lambda _: audit.verify(), range(8))), list(range(1,9)))

    def test_startup_timeout_is_bounded_and_sanitized(self):
        from unittest.mock import patch
        with patch.object(agentxd_audit.SwiftAudit, 'startup_timeout', .1):
            with self.assertRaisesRegex(ValueError, '^audit helper unavailable$'):
                self.session("import time\ntime.sleep(10)\n")

    def test_input_limit_seals_child_before_sending_request(self):
        audit = self.session("import sys\nprint('{\"ok\":true,\"ready\":true}',flush=True)\nfor line in sys.stdin: print('{\"ok\":true}',flush=True)\n")
        self.addCleanup(audit.close)
        with self.assertRaisesRegex(ValueError, '^audit helper unavailable$'):
            audit.call({'op': 'append', 'record': {'private': 'x'*16384}})
        self.assertIsNotNone(audit.process.poll())

    def test_startup_cancellation_reaps_child_and_preserves_system_exit(self):
        import subprocess
        from unittest.mock import patch
        original = subprocess.Popen
        children = []
        def spawn(*args, **kwargs):
            child = original(*args, **kwargs); children.append(child); return child
        try:
            with patch.object(subprocess, 'Popen', side_effect=spawn), \
                 patch.object(agentxd_audit.SwiftAudit, '_read_frame', side_effect=SystemExit(7)):
                with self.assertRaises(SystemExit) as error:
                    self.session("import time\ntime.sleep(10)\n")
                self.assertEqual(error.exception.code, 7)
            self.assertIsNotNone(children[0].poll())
            self.assertTrue(children[0].stdin.closed)
            self.assertTrue(children[0].stdout.closed)
        finally:
            for child in children:
                if child.poll() is None: child.kill(); child.wait()
                child.stdin.close(); child.stdout.close()
