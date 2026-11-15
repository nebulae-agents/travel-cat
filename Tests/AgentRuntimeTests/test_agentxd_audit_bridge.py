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
        self.bridge("import json,sys\njson.load(sys.stdin)\nprint('{\"ok\":true,\"records\":0}')\n")
        self.helper.rename(binaries / 'Fixture')
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable='Fixture')))
        class Done(Exception):
            pass
        def ready(store):
            self.assertEqual(store.audit.verify(), 0)
            self.assertTrue((self.root / '.agentxd-endpoint.json').is_file())
            raise Done()
        with self.assertRaises(Done):
            serve(self.root, on_ready=ready, pi_bundle=bundle)
        self.assertFalse((self.root / '.agentxd-endpoint.json').exists())
