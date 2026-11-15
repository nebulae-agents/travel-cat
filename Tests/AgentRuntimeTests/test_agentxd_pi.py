"""Subprocess ownership and cancellation contract for the agentxd Pi adapter."""
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Runtime"))
from agentxd_pi import PiProcess


class PiProcessTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.bundle = Path(self.work.name) / "Fixture.app"
        self.node = self.bundle / "Contents/Helpers/PiAgent/node"
        self.node.parent.mkdir(parents=True)
        self.runner = self.bundle / "Contents/Resources/PiAgent/runner.mjs"
        self.runner.parent.mkdir(parents=True)
        self.runner.touch()

    def execute(self, script):
        self.node.write_text("#!/usr/bin/python3\n" + script)
        self.node.chmod(0o700)
        return PiProcess(self.bundle, "http://127.0.0.1:9999/v1", "fixture",
                         [{"role": "user", "content": "hello"}])

    def test_natural_completion_before_late_stop_retains_result_and_owner(self):
        child = self.execute("""import json, os, sys
request = json.load(sys.stdin)
assert request['secret'] == '' and 'HOME' not in os.environ
assert request['messages'][-1]['content'] == 'hello'
print(json.dumps({'version':1, 'ok':True, 'text':'complete'}))
""")
        launched = []
        result = child.run(launched.append)
        child.request_stop()
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["response"], "complete")
        self.assertEqual(result["stopEvidence"], "confirmedExited")
        evidence = result["processEvidence"]
        self.assertEqual(evidence["launchID"], launched[0]["launchID"])
        self.assertEqual(evidence["child"]["pid"], launched[0]["childPID"])
        self.assertGreater(evidence["child"]["seconds"], 0)
        self.assertEqual(evidence["owner"]["pid"], os.getpid())
        self.assertEqual(evidence["exitCode"], 0)
        self.assertTrue(evidence["reaped"])
        with self.assertRaises(ChildProcessError):
            os.waitpid(evidence["childPID"], os.WNOHANG)

    def test_uncooperative_child_is_killed_and_reaped(self):
        # Touch a proof that the child consumed input and installed SIG_IGN before stopping.
        ready = Path(self.work.name) / "ready"
        child = self.execute("import json, signal, sys, time\n"
                             "from pathlib import Path\n"
                             "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                             "json.load(sys.stdin)\n"
                             f"Path({str(ready)!r}).touch()\n"
                             "time.sleep(30)\n")
        result = {}
        thread = threading.Thread(target=lambda: result.update(child.run(lambda _: None)))
        thread.start()
        try:
            for _ in range(100):
                if ready.exists():
                    break
                thread.join(.02)
            self.assertTrue(ready.exists())
        finally:
            child.request_stop()
            child.request_stop()
            thread.join(4)
        self.assertFalse(thread.is_alive())
        self.assertEqual(result["status"], "cancelled")
        self.assertEqual(result["stopEvidence"], "confirmedExited")
        self.assertEqual(result["processEvidence"]["exitCode"], -signal.SIGKILL)
        self.assertTrue(result["processEvidence"]["reaped"])

    def test_launch_failure_has_no_exit_confirmation(self):
        child = PiProcess(self.bundle, "http://127.0.0.1:9999", "test",
                          [{"role": "user", "content": "test"}])
        result = child.run(lambda _: self.fail("unexpected launch"))
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["stopEvidence"], "unverified")
        self.assertFalse(result["processEvidence"]["reaped"])

    def test_rejects_external_endpoints_and_nonempty_credentials(self):
        for base, secret in (("https://openrouter.ai/api/v1", ""), ("http://localhost.test", ""),
                             ("http://127.0.0.1", "not-a-real-key")):
            with self.subTest(base=base), self.assertRaises(ValueError):
                PiProcess(self.bundle, base, "test", [{"role": "user", "content": "test"}], secret=secret)


if __name__ == "__main__":
    unittest.main()
