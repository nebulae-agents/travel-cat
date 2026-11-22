"""Exercise run ownership through one agentxd endpoint on a private fixture root."""
from contextlib import contextmanager
import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from textwrap import dedent
import time
import unittest

from websockets.sync.client import connect


RUNTIME = Path(__file__).resolve().parents[2] / "Runtime/agentxd.py"


class TestMultiAppRuntime(unittest.TestCase):
    def setUp(self):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        for app_id in ("alpha", "beta"):
            app = self.root / "apps" / app_id
            (app / "runs").mkdir(parents=True)
            (app / "app.yaml").touch()
            member = app / "instances/pi/config"
            member.mkdir(parents=True)
            (member / "agent.yaml").touch()
        self.endpoint_file = self.root / ".agentxd-endpoint.json"
        self.helper = self.executable(self.root / "audit-helper", """
            import json
            from pathlib import Path
            import sys
            from uuid import UUID

            mode, root_flag, path, app_flag, app_id = sys.argv[1:]
            assert (mode, root_flag, app_flag) == ("--agentx-audit-session", "--root", "--app")
            root = Path(path)
            if (root / ("fail-" + app_id)).exists():
                sys.exit(1)
            print(json.dumps({"ok": True, "ready": True}), flush=True)
            records = []
            for line in sys.stdin:
                request = json.loads(line)
                if request["op"] == "append":
                    assert request["record"]["appId"] == app_id
                    records.append(request["record"])
                    response = {}
                elif request["op"] == "verify":
                    response = {"records": len(records)}
                else:
                    assert str(UUID(request["runId"])) == request["runId"].lower()
                    response = {"records": [r for r in records if r["taskId"] == request["runId"]]}
                print(json.dumps(dict(response, ok=True)), flush=True)
            (root / ("closed-" + app_id)).touch()
        """)
        self.marker(apps=[{"appID": "alpha"}, {"appID": "beta"}])

    def marker(self, **changes):
        config = dict(root=str(self.root), version=2)
        config.update(changes)
        (self.root / ".agentxd-pilot.json").write_text(json.dumps(config))

    @staticmethod
    def executable(path, source):
        path.write_text("#!" + sys.executable + "\n" + dedent(source))
        path.chmod(0o700)
        return path

    def run_path(self, app, run_id):
        return self.root / "apps" / app / "runs" / (run_id + ".json")

    def seed(self, app, run_id, status):
        self.run_path(app, run_id).write_text(json.dumps({
            "id": run_id, "appID": app, "instanceID": "pi", "status": status, "revision": 1,
            "isRead": False, "events": [{
                "eventId": run_id + ":1", "runId": run_id, "revision": 1, "kind": "created", "state": status,
            }],
        }))

    @contextmanager
    def launch(self, *args):
        with subprocess.Popen(
            [sys.executable, str(RUNTIME), "--root", str(self.root), "--audit-helper", str(self.helper), *args],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
        ) as process:
            try:
                yield process
            finally:
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                    self.fail("agentxd did not shut down")

    def await_condition(self, check, description):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            value = check()
            if value:
                return value
            time.sleep(.02)
        self.fail("timed out waiting for " + description)

    @contextmanager
    def service(self, *args):
        with self.launch(*args) as process:
            def ready():
                if process.poll() is not None:
                    self.fail("agentxd exited before endpoint publication: " + process.stderr.read())
                if self.endpoint_file.exists():
                    return json.loads(self.endpoint_file.read_text())

            self.endpoint = self.await_condition(ready, "agentxd endpoint")
            yield
        self.assertEqual(process.returncode, 0)
        self.assertFalse(self.endpoint_file.exists())

    def request(self, method, app, route="", *, body=None, key=None, authorized=True):
        headers = {}
        if authorized:
            headers["Authorization"] = "Bearer " + self.endpoint["token"]
        if key is not None:
            headers["Idempotency-Key"] = key
        if body is not None:
            headers["Content-Type"] = "application/json"
        connection = http.client.HTTPConnection("127.0.0.1", self.endpoint["port"], timeout=5)
        try:
            connection.request(method, f"/v1/apps/{app}/runs{route}",
                               json.dumps(body) if body is not None else None, headers)
            response = connection.getresponse()
            return response.status, json.load(response)
        finally:
            connection.close()

    def events(self, app, run_id):
        return connect(
            f"ws://127.0.0.1:{self.endpoint['port']}/v1/apps/{app}/runs/{run_id}/events?after=0",
            additional_headers={"Authorization": "Bearer " + self.endpoint["token"]}, proxy=None, close_timeout=1,
        )

    def test_same_run_id_stays_with_its_app_for_reads_events_and_updates(self):
        self.seed("alpha", "shared", "completed")
        self.seed("beta", "shared", "failed")
        self.seed("beta", "beta-only", "completed")
        untouched = self.run_path("beta", "shared").read_bytes()

        with self.service():
            endpoint_bytes = self.endpoint_file.read_bytes()
            with self.launch() as duplicate:
                _, stderr = duplicate.communicate(timeout=5)
                self.assertNotEqual(duplicate.returncode, 0)
                self.assertIn("pilot root already in use", stderr)
            self.assertTrue(self.endpoint_file.read_bytes() == endpoint_bytes)
            self.assertEqual([r["id"] for r in self.request("GET", "alpha")[1]], ["shared"])
            self.assertEqual({r["id"] for r in self.request("GET", "beta")[1]}, {"shared", "beta-only"})
            self.assertEqual(self.request("GET", "unknown")[0], 404)
            self.assertEqual(self.request("GET", "alpha", authorized=False)[0], 401)
            for tail in ("", "/audit", "/events?after=0"):
                self.assertEqual(self.request("GET", "alpha", "/beta-only" + tail)[0], 404)
            self.assertEqual(self.request("POST", "alpha", "/beta-only/stop", key="stop")[0], 404)
            self.assertEqual(self.request("PATCH", "alpha", "/beta-only", body={"expectedRevision": 1, "isRead": True})[0], 404)
            with self.events("alpha", "shared") as alpha, self.events("beta", "shared") as beta:
                self.assertEqual(json.loads(alpha.recv(2))["state"], "completed")
                self.assertEqual(json.loads(beta.recv(2))["state"], "failed")
                self.assertEqual(self.request("PATCH", "alpha", "/shared", body={"expectedRevision": 1, "isRead": True})[0], 200)
                self.assertEqual(json.loads(alpha.recv(2))["kind"], "readFlagChanged")
                self.assertEqual(self.request("PATCH", "alpha", "/shared", body={"expectedRevision": 1, "isRead": False})[0], 409)
                self.assertEqual(self.request("GET", "beta", "/shared/events?after=1"), (200, {"revision": 1, "events": []}))
                self.assertTrue(beta.ping().wait(2))
            for app in ("alpha", "beta"):
                for _ in range(2):
                    self.assertEqual(self.request("GET", app, "/shared/audit"), (200, {
                        "runId": "shared", "appID": app, "auditStatus": "legacy", "verified": True,
                        "chainRecords": 0, "records": [],
                    }))

        self.assertEqual(self.run_path("beta", "shared").read_bytes(), untouched)
        with self.service():
            self.assertTrue(self.request("GET", "alpha", "/shared")[1]["isRead"])
            self.assertFalse(self.request("GET", "beta", "/shared")[1]["isRead"])
            self.assertEqual(self.request("GET", "alpha", "/shared/events?after=1")[1]["events"][0]["revision"], 2)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS process birth identity")
    def test_same_create_and_stop_keys_are_independent_across_apps_and_restart(self):
        def binding(app):
            return dict(appID=app, pi=dict(instanceID="pi", providerID=app, model=app,
                                          baseURL="http://127.0.0.1:9988/v1", systemPrompt="System"))
        self.marker(apps=[binding("alpha"), binding("beta")])
        bundle = self.root / "Fixture.app"
        node = bundle / "Contents/Helpers/PiAgent/node"
        node.parent.mkdir(parents=True)
        runner = bundle / "Contents/Resources/PiAgent/runner.mjs"
        runner.parent.mkdir(parents=True)
        runner.touch()
        self.executable(node, f"""
            import json
            from pathlib import Path
            import sys
            import time

            request = json.loads(sys.stdin.readline())
            root = Path({str(self.root)!r})
            model = request["model"]
            (root / ("running-" + model)).touch()
            while not (root / ("finish-" + model)).exists():
                time.sleep(.02)
            print(json.dumps({{"ok": True, "version": 1, "text": model}}), flush=True)
        """)
        body = {"instanceId": "pi", "prompt": "same prompt"}

        def wait_for_run(app, run_id, predicate):
            def read():
                status, run = self.request("GET", app, "/" + run_id)
                return run if status == 200 and run.get("auditStatus") == "confirmed" and predicate(run) else None
            return self.await_condition(read, "run state in " + app)

        with self.service("--pi-bundle", str(bundle)):
            status, alpha = self.request("POST", "alpha", body=body, key="create")
            self.assertEqual(status, 201)
            status, beta = self.request("POST", "beta", body=body, key="create")
            self.assertEqual(status, 201)
            alpha_id, beta_id = alpha["id"], beta["id"]
            self.assertNotEqual(alpha_id, beta_id)
            for app in ("alpha", "beta"):
                self.await_condition((self.root / ("running-" + app)).exists, app + " Pi request")
            self.assertEqual(self.request("POST", "alpha", "/" + beta_id + "/stop", key="stop")[0], 404)
            self.assertEqual(self.request("POST", "alpha", "/" + alpha_id + "/stop", key="stop")[0], 202)
            cancelled = wait_for_run("alpha", alpha_id, lambda run: run["status"] == "cancelled")
            self.assertEqual(cancelled["stopEvidence"], "confirmedExited")
            self.assertEqual(self.request("GET", "beta", "/" + beta_id)[1]["status"], "running")
            (self.root / "finish-beta").touch()
            completed = wait_for_run("beta", beta_id, lambda run: run["status"] == "completed")
            self.assertEqual(completed["response"], "beta")
            self.assertEqual(self.request("POST", "beta", "/" + beta_id + "/stop", key="stop"), (200, completed))
            for app, run_id, phases in (("alpha", alpha_id, ["started", "cancel_requested", "cancelled"]),
                                        ("beta", beta_id, ["started", "completed"])):
                status, audit = self.request("GET", app, "/" + run_id + "/audit")
                self.assertEqual(status, 200)
                self.assertEqual(audit["chainRecords"], len(phases))
                self.assertEqual([row["kind"] for row in audit["records"]], ["model.request." + phase for phase in phases])
                self.assertEqual({(row["appId"], row["taskId"]) for row in audit["records"]}, {(app, run_id)})

        for app in ("alpha", "beta"):
            self.assertTrue((self.root / ("closed-" + app)).exists())
        with self.service("--pi-bundle", str(bundle)):
            self.assertEqual(self.request("POST", "alpha", body=body, key="create"), (200, cancelled))
            self.assertEqual(self.request("POST", "beta", body=body, key="create"), (200, completed))
            self.assertEqual(self.request("GET", "beta", "/" + alpha_id)[0], 404)

    def test_v2_requires_unambiguous_app_declarations(self):
        for changes in (
            {"apps": []},
            {"apps": {"alpha": {}}},
            {"apps": [{"appID": "alpha"}, {"appID": "alpha"}]},
            {"apps": [{"appID": "alpha"}, {"appID": "Beta"}]},
            {"apps": [{"appID": "blackcat"}]},
            {"apps": [{"appID": "workbench"}]},
            {"apps": [{"appID": "alpha"}, None]},
            {"apps": [{"appID": "alpha", "pi": None}]},
            {"apps": [{"appID": "alpha", "pi": {"instanceID": "pi"}}]},
            {"apps": [{"appID": "alpha", "extra": True}]},
            {"apps": [{"appID": "alpha"}], "appID": "alpha"},
            {"apps": [{"appID": "alpha"}], "pi": {}},
            {"apps": [{"appID": "alpha"}], "version": 2.0},
        ):
            with self.subTest(changes=changes):
                self.marker(**changes)
                with self.launch() as process:
                    _, stderr = process.communicate(timeout=5)
                    self.assertNotEqual(process.returncode, 0, stderr)
                self.assertFalse(self.endpoint_file.exists())
                self.assertFalse((self.root / "closed-alpha").exists())

    def test_ownership_marker_accepts_two_bindings_and_rejects_oversized_input(self):
        binding = {"instanceID": "pi", "providerID": "test", "model": "fixture",
                   "baseURL": "http://127.0.0.1:9", "systemPrompt": "x" * 34_000}
        self.marker(apps=[{"appID": "alpha", "pi": binding}, {"appID": "beta", "pi": binding}])
        with self.service():
            self.assertEqual(self.request("GET", "alpha"), (200, []))
            self.assertEqual(self.request("GET", "beta"), (200, []))

        marker = self.root / ".agentxd-pilot.json"
        marker.write_bytes(b" " * (2 * 1024 * 1024) + marker.read_bytes())
        with self.launch() as process:
            _, stderr = process.communicate(timeout=5)
            self.assertNotEqual(process.returncode, 0)
            self.assertIn("pilot ownership marker is too large", stderr)
        self.assertFalse(self.endpoint_file.exists())

    def test_ownership_marker_must_be_a_regular_file_without_aliases(self):
        marker = self.root / ".agentxd-pilot.json"
        original = marker.rename(self.root / "original.json")
        for link in (os.symlink, os.link):
            with self.subTest(link=link.__name__):
                link(original, marker)
                with self.launch() as process:
                    _, stderr = process.communicate(timeout=5)
                    self.assertNotEqual(process.returncode, 0, stderr)
                self.assertFalse(self.endpoint_file.exists())
                marker.unlink()

    def test_failed_second_audit_start_closes_first_session_and_releases_root(self):
        failed = self.root / "fail-beta"
        failed.touch()
        with self.launch() as process:
            _, stderr = process.communicate(timeout=5)
            self.assertNotEqual(process.returncode, 0)
            self.assertIn("audit helper unavailable", stderr)
        self.assertFalse(self.endpoint_file.exists())
        self.assertTrue((self.root / "closed-alpha").exists())
        failed.unlink()
        with self.service():
            self.assertEqual(self.request("GET", "alpha"), (200, []))
            self.assertEqual(self.request("GET", "beta"), (200, []))
