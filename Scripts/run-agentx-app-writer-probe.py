#!/usr/bin/env python3
"""Verify a debug App writer with the bundled Pi runtime and a loopback model."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer

REPO = Path(__file__).resolve().parents[1]
pilot = runpy.run_path(str(REPO / "Scripts/run-agentx-pi-pilot-acceptance.py"))
contract = runpy.run_path(str(REPO / "Tests/AgentRuntimeTests/test_agentxd_api_contract.py"))
case = contract["TestAgentxdApiContract"]()


def check(binary, bundle, root, server):
    args = [binary, "--agentx-app-writer-probe", root, bundle, str(server.server_port)]
    with subprocess.Popen(args, stderr=subprocess.PIPE, text=True) as app:
        try:
            endpoint = case.wait_for_endpoint(root, app)
            endpoint_file = root / ".agentxd-endpoint.json"
            for other, expected in [(args, "writer probe unavailable"),
                                    ([sys.executable, "-B", REPO / "Tests/AgentRuntimeTests/agentxd_reference.py", "--root", root],
                                     "pilot root already in use")]:
                rejected = subprocess.run(other, capture_output=True, text=True, timeout=8)
                case.assertNotEqual(rejected.returncode, 0)
                case.assertIn(expected, rejected.stderr)
            path = "/v1/apps/pilot/runs"
            post = {"instanceId": "pi", "prompt": pilot["PROMPT"]}
            schema = json.loads((REPO / "api/agentxd.openapi.json").read_bytes())["paths"][contract["APP_PATH"]]
            for method, expected in [("get", {200, 401}), ("post", {200, 201, 401, 409, 422})]:
                case.assertTrue({str(status) for status in expected}.issubset(schema[method]["responses"]))
            case.assertEqual(case.exchange(endpoint, "GET", path, None), (200, []))
            case.assertEqual(case.exchange(endpoint, "POST", path, post, authorize=False)[0], 401)
            case.assertEqual(case.exchange(endpoint, "POST", path, dict(post, instanceId="other"))[0], 422)
            status, run = case.exchange(endpoint, "POST", path, post)
            case.assertEqual(status, 201)
            case.assertTrue(server.accepted.wait(15), "bundled Pi did not reach the local model")
            case.assertEqual(case.exchange(endpoint, "POST", path, post), (200, run))
            case.assertEqual(case.exchange(endpoint, "POST", path, dict(post, prompt="changed"))[0], 409)
            cli = subprocess.check_output([REPO / "Scripts/agentx", "--root", root, "run", "list", "--app", "pilot"], timeout=8)
            case.assertEqual(json.loads(cli), [run])
            receipt_file, = (root / "manager/pi-processes").glob("*.json")
            receipt = json.loads(receipt_file.read_bytes())
            pid = receipt["child"]["pid"]
            case.assertEqual(receipt["owner"]["pid"], app.pid)
            case.assertEqual(receipt["runID"], run["id"])
            child_path = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "comm="], text=True).strip()
            case.assertEqual(Path(child_path).resolve(), (bundle / "Contents/Helpers/PiAgent/node").resolve())
            app.terminate()
            case.assertEqual(app.wait(timeout=12), 0)
            case.assertFalse(endpoint_file.exists())
            with case.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
            with case.assertRaises(OSError):
                case.exchange(endpoint, "GET", path, None)
            case.assertTrue(json.loads(receipt_file.read_bytes())["reaped"])
            final = json.loads((root / "apps/pilot/runs" / (run["id"] + ".json")).read_bytes())
            case.assertEqual((final["status"], final["stopEvidence"]), ("cancelled", "confirmedExited"))
            case.assertGreater(final["revision"], run["revision"])
            case.assertEqual(server.count, 1)
            fd = os.open(root, os.O_RDONLY)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(fd)
        finally:
            if app.poll() is None:
                app.terminate()
                try:
                    app.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    app.kill()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("pi_bundle", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="agentx-app-writer-", dir="/private/tmp") as directory:
        with ThreadingHTTPServer(("127.0.0.1", 0), pilot["StreamingModel"]) as server:
            server.accepted, server.done = threading.Event(), threading.Event()
            server.count_lock, server.count = threading.Lock(), 0
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                check(args.binary.resolve(strict=True), args.pi_bundle.resolve(strict=True), Path(directory), server)
            finally:
                server.done.set()
                server.shutdown()
    print("PASS: App owns HTTP and the Pi child; one model request; quit reaps Pi and releases the endpoint and root.")
