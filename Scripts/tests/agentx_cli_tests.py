import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


CLI = Path(__file__).resolve().parents[1] / "agentx"


class AgentXCliTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(CLI.is_file(), "pilot run CLI must exist")
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.run_record = {"id": "one", "appID": "pilot", "instanceID": "pi", "status": "running",
                           "revision": 1, "processEvidence": {"childPID": 123, "reaped": False}}
        self.requests = []
        record, requests = self.run_record, self.requests

        class Handler(BaseHTTPRequestHandler):
            def handle_run(self):
                requests.append((self.command, self.path, self.headers))
                if self.command == "POST":
                    length = int(self.headers.get("Content-Length", 0))
                    self.rfile.read(length)
                    self.send_response(202)
                else:
                    self.send_response(200)
                self.end_headers()
                data = [record] if self.path.endswith("/runs") else record
                self.wfile.write(json.dumps(data).encode())

            do_GET = do_POST = handle_run

            def log_message(self, *_):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.addCleanup(self.server.server_close)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.shutdown)
        endpoint = self.root / ".agentxd-endpoint.json"
        endpoint.write_text(json.dumps({"port": self.server.server_port, "token": "test-only-token"}))
        endpoint.chmod(0o600)

    def cli(self, *args):
        return subprocess.run([sys.executable, str(CLI), "run", *args, "--app", "pilot"],
                              env=dict(os.environ, AGENTX_ROOT=str(self.root)), text=True, capture_output=True)

    def test_list_show_and_stop_use_authenticated_service(self):
        listing = self.cli("list")
        self.assertEqual(listing.returncode, 0, listing.stderr)
        self.assertEqual(json.loads(listing.stdout), [self.run_record])
        show = self.cli("show", "--run", "one")
        self.assertEqual(show.returncode, 0, show.stderr)
        self.assertEqual(json.loads(show.stdout), self.run_record)
        self.run_record.update(status="cancelling", stopEvidence="pending", revision=2)
        stop = self.cli("stop", "--run", "one", "--idempotency-key", "stop.v1:retry-1")
        self.assertEqual(stop.returncode, 0, stop.stderr)
        self.assertEqual(json.loads(stop.stdout), self.run_record)
        self.assertEqual([(method, path) for method, path, _ in self.requests], [
            ("GET", "/v1/apps/pilot/runs"), ("GET", "/v1/apps/pilot/runs/one"), ("POST", "/v1/apps/pilot/runs/one/stop")])
        self.assertTrue(all(headers["Authorization"] == "Bearer test-only-token" for _, _, headers in self.requests))
        self.assertEqual(self.requests[-1][2]["Idempotency-Key"], "stop.v1:retry-1")

    def test_offline_service_does_not_read_local_run_fallback(self):
        directory = self.root / "apps/pilot/runs"
        directory.mkdir(parents=True)
        saved = directory / "one.json"
        saved.write_text(json.dumps(self.run_record))
        (self.root / ".agentxd-endpoint.json").unlink()
        out = self.cli("stop", "--run", "one")
        self.assertNotEqual(out.returncode, 0)
        self.assertFalse(out.stdout)
        self.assertEqual(json.loads(saved.read_text()), self.run_record)

    def test_invalid_run_id_never_sends_a_request(self):
        out = self.cli("stop", "--run", "../other")
        self.assertNotEqual(out.returncode, 0)
        self.assertFalse(self.requests)


if __name__ == "__main__":
    unittest.main()
