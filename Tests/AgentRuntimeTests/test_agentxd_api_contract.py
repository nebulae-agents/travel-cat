"""Exercise the published agentxd HTTP contract against a private two-app service."""
import http.client
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[2]
APP_PATH = "/v1/apps/{appId}/runs"
RUN_PATH = APP_PATH + "/{runId}"


class TestAgentxdApiContract(unittest.TestCase):
    def test_documented_routes_and_statuses_match_service(self):
        document = REPO / "api" / "agentxd.openapi.json"
        self.assertTrue(document.is_file(), "the shared agentxd HTTP contract is missing")
        contract = json.loads(document.read_bytes())
        cases = [
            ("GET", APP_PATH, "", None, 200),
            ("POST", APP_PATH, "", {"instanceId": "pi", "prompt": "fixture"}, 503),
            ("GET", RUN_PATH, "", None, 200),
            ("PATCH", RUN_PATH, "", {"expectedRevision": 0, "isRead": True}, 200),
            ("PATCH", RUN_PATH, "", {"expectedRevision": 0, "isRead": False}, 409),
            ("GET", RUN_PATH + "/events", "?after=0", None, 200),
            ("GET", RUN_PATH + "/events", "?after=99", None, 409),
            ("POST", RUN_PATH + "/stop", "", {}, 409),
            ("GET", RUN_PATH + "/audit", "", None, 503),
        ]
        declared = {(method.upper(), path) for path, entry in contract["paths"].items()
                    for method in entry if method in {"get", "post", "patch"}}
        self.assertEqual(declared, {(method, path) for method, path, _, _, _ in cases})
        self.assertEqual(contract["security"], [{"localBearer": []}])

        with tempfile.TemporaryDirectory() as workspace:
            root = Path(workspace).resolve()
            for app in ("alpha", "beta"):
                directory = root / "apps" / app
                (directory / "runs").mkdir(parents=True)
                (directory / "app.yaml").write_text("id: " + app + "\n")
                (directory / "runs/shared.json").write_text(json.dumps({
                    "appID": app, "id": "shared", "instanceID": "pi", "status": "completed",
                    "prompt": "fixture", "response": app, "startedAt": 0, "endedAt": 1,
                    "stopEvidence": "confirmedExited", "isRead": False,
                }))
            (root / ".agentxd-pilot.json").write_text(json.dumps({
                "root": str(root), "version": 2, "apps": [{"appID": "alpha"}, {"appID": "beta"}],
            }))
            with subprocess.Popen(
                [sys.executable, "-B", str(REPO / "Runtime/agentxd.py"), "--root", str(root)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            ) as service:
                try:
                    endpoint = self.wait_for_endpoint(root, service)
                    for method, template, query, body, expected in cases:
                        with self.subTest(method=method, template=template, expected=expected):
                            statuses = contract["paths"][template][method.lower()]["responses"]
                            self.assertIn("401", statuses)
                            self.assertIn(str(expected), statuses)
                            path = template.format(appId="beta", runId="shared") + query
                            self.assertEqual(self.exchange(endpoint, method, path, body, authorize=False)[0], 401)
                            status, data = self.exchange(endpoint, method, path, body)
                            self.assertEqual(status, expected, data)
                            if (method, template) == ("GET", RUN_PATH):
                                fields = contract["components"]["schemas"]["Run"]["properties"]
                                for name, value in {
                                    "appID": "beta", "prompt": "fixture", "response": "beta",
                                    "startedAt": 0, "endedAt": 1, "stopEvidence": "confirmedExited",
                                }.items():
                                    with self.subTest(field=name):
                                        self.assertIn(name, fields)
                                        self.assertEqual(data[name], value)
                                evidence = fields["stopEvidence"]["$ref"].split("/")[-1]
                                self.assertIn(data["stopEvidence"], contract["components"]["schemas"][evidence]["enum"])
                            if isinstance(data, dict) and "appID" in data:
                                self.assertEqual(data["appID"], "beta")
                    self.assertFalse(self.exchange(endpoint, "GET", "/v1/apps/alpha/runs/shared", None)[1]["isRead"])
                    cli = subprocess.check_output(
                        [sys.executable, "-B", str(REPO / "Scripts/agentx"), "--root", str(root),
                         "run", "show", "--app", "beta", "--run", "shared"], timeout=8,
                    )
                    cli_run = json.loads(cli)
                    self.assertEqual((cli_run["appID"], cli_run["response"], cli_run["isRead"]), ("beta", "beta", True))
                finally:
                    if service.poll() is None:
                        service.terminate()
                    try:
                        service.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        service.kill()
                        service.wait(timeout=10)

    def wait_for_endpoint(self, root, service):
        path = root / ".agentxd-endpoint.json"
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if path.is_file():
                return json.loads(path.read_bytes())
            if service.poll() is not None:
                self.fail(service.stderr.read())
            time.sleep(0.03)
        self.fail("service did not publish its endpoint")

    @staticmethod
    def exchange(endpoint, method, path, body, authorize=True):
        connection = http.client.HTTPConnection("127.0.0.1", endpoint["port"], timeout=5)
        headers = {"Content-Type": "application/json", "Idempotency-Key": "contract-fixture"}
        if authorize:
            headers["Authorization"] = "Bearer " + endpoint["token"]
        try:
            connection.request(method, path, json.dumps(body) if body is not None else None, headers=headers)
            response = connection.getresponse()
            return response.status, json.load(response)
        finally:
            connection.close()
