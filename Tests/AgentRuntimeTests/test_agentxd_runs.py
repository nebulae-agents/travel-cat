import json
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Runtime"))
from agentxd import RunStore
from agentxd_runs import PilotRuns, CommandError


class ControlledPi:
    def __init__(self, *args):
        self.launched = threading.Event()
        self.finish = threading.Event()
        self.stops = 0

    def request_stop(self):
        self.stops += 1

    def run(self, on_launch):
        identity = {"launchID": "fixture", "childPID": 999}
        on_launch(identity)
        self.launched.set()
        self.finish.wait(3)
        return {"status": "cancelled" if self.stops else "completed", "response": "",
                "stopEvidence": "confirmedExited", "processEvidence": dict(identity, reaped=True, exitCode=0)}


class TestPilotCommands(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name).resolve()
        app = root / "apps/pilot"
        (app / "runs").mkdir(parents=True)
        (app / "app.yaml").touch()
        instance = app / "instances/pi/config"
        instance.mkdir(parents=True)
        (instance / "agent.yaml").touch()
        pi = dict(instanceID="pi", providerID="local", model="fixture", baseURL="http://127.0.0.1:9988/v1", systemPrompt="System")
        (root / ".agentxd-pilot.json").write_text(json.dumps(dict(appID="pilot",root=str(root),pi=pi)))
        self.store = RunStore(root)
        self.children = []
        def factory(*args):
            child = ControlledPi(*args)
            self.children.append(child)
            return child
        self.make = lambda: PilotRuns(self.store, root, factory)
        self.service = self.make()
        self.addCleanup(self.service.close)
        self.body = dict(instanceId="pi",prompt="hello")

    def test_duplicate_create_and_stop_share_child_and_evidence_across_restart(self):
        code, run = self.service.create("key", self.body)
        self.assertEqual(code, 201)
        child = self.children[0]
        self.assertTrue(child.launched.wait(2))
        self.assertEqual(self.service.create("key", self.body)[1]["id"], run["id"])
        with self.assertRaises(CommandError) as conflict:
            self.service.create("key", dict(self.body, prompt="different"))
        self.assertEqual(conflict.exception.status, 409)
        self.assertEqual(len(self.children), 1)
        code, pending = self.service.stop(run["id"], "stop-key")
        self.assertEqual((code, pending["status"], pending["stopEvidence"]), (202, "cancelling", "pending"))
        self.service.stop(run["id"], "second-stop")
        self.assertEqual(child.stops, 1)
        child.finish.set()
        self.service.close()
        final = self.store.get(run["id"])
        self.assertEqual((final["status"], final["stopEvidence"], final["processEvidence"]["reaped"]), ("cancelled", "confirmedExited", True))
        resumed = self.make()
        self.assertEqual(resumed.create("key", self.body), (200, final))
        self.assertEqual(resumed.stop(run["id"], "stop-key"), (200, final))
        self.assertEqual(len(self.children), 1)

    def test_stop_after_natural_exit_leaves_completed_record_unchanged(self):
        _, run = self.service.create("key", self.body)
        child = self.children[0]
        self.assertTrue(child.launched.wait(2))
        with self.store.lock:
            worker = self.service.workers[run["id"]][1]
        child.finish.set()
        worker.join(3)
        self.assertFalse(worker.is_alive())
        completed = self.store.get(run["id"])
        self.assertEqual(completed["status"], "completed")
        self.assertEqual(self.service.stop(run["id"], "late-stop"), (200, completed))
        self.assertEqual(child.stops, 0)

    def test_recovery_never_claims_exit_or_starts_second_child(self):
        _, run = self.service.create("key", self.body)
        self.assertTrue(self.children[0].launched.wait(2))
        self.service.stop(run["id"], "stop-key")
        path = self.store.directory / (run["id"] + ".json")
        interrupted = path.read_bytes()
        self.children[0].finish.set()
        self.service.close()
        path.write_bytes(interrupted)  # persisted snapshot at the crash boundary
        resumed = self.make()
        recovered = resumed.create("key", self.body)[1]
        self.assertEqual(recovered["stopEvidence"], "unverified")
        self.assertNotEqual(recovered["status"], "cancelled")
        with self.assertRaises(CommandError):
            resumed.create("new-key", self.body)
        self.assertEqual(len(self.children), 1)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS process birth identity")
    def test_recovery_leaves_other_process_with_matching_pid_untouched(self):
        from agentxd_pi import _identity

        # Give the old receipt a real, live PID but a different birth time.
        # The subprocess is part of this fixture and must still answer after recovery and stop.
        with subprocess.Popen([sys.executable, "-I", "-c", "print(input(), flush=True)"],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as witness:
            try:
                live = _identity(witness.pid)
                evidence = {"launchID": "previous-launch", "childPID": witness.pid,
                            "child": dict(live, seconds=live["seconds"] - 1), "reaped": False}
                old = dict(id="interrupted", appID="pilot", instanceID="pi", status="cancelling",
                           revision=3, pilotCreateKey="fixture-key", stopEvidence="pending",
                           processEvidence=evidence, stopRequestedAt=100)
                self.store.insert(old)
                resumed = self.make()
                recovered = self.store.get(old["id"])
                self.assertEqual((recovered["revision"], recovered["status"], recovered["stopEvidence"]),
                                 (4, "failed", "unverified"))
                self.assertTrue(recovered["requiresProcessReview"])
                self.assertEqual(recovered["processEvidence"], evidence)
                self.assertEqual(resumed.stop(old["id"], "retry-stop"), (200, recovered))
                with self.assertRaises(CommandError) as busy:
                    resumed.create("new-key", self.body)
                self.assertEqual((busy.exception.status, busy.exception.reason), (409, "instance_busy"))
                self.assertEqual(_identity(witness.pid), live)
                response, _ = witness.communicate("still running\n", timeout=5)
                self.assertEqual((witness.returncode, response.strip()), (0, "still running"))
                self.assertEqual(self.children, [])
            finally:
                if witness.poll() is None:
                    witness.kill()
                    witness.wait()

    def test_invalid_binding_and_unmanaged_history(self):
        with self.assertRaises(CommandError) as unbound:
            self.service.create("key", dict(self.body, instanceId="foreign"))
        self.assertEqual(unbound.exception.status, 422)
        path = self.store.directory / "old.json"
        path.write_text(json.dumps(dict(id="old",appID="pilot",instanceID="pi",status="running")))
        old = path.read_bytes()
        with self.assertRaises(CommandError):
            self.service.stop("old", "key")
        self.assertEqual(path.read_bytes(),old)
        self.assertFalse(self.children)


if __name__ == "__main__":
    unittest.main()
