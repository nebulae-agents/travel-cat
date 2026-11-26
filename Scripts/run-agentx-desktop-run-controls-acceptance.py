#!/usr/bin/env python3
"""Compare run lookup, stopping and read-state updates over the two real HTTP endpoints."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import hashlib
import http.client
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import threading

HERE = Path(__file__).resolve().parent
multi = runpy.run_path(str(HERE / "run-agentx-desktop-multi-app-acceptance.py"))
fixture, case = multi["fixture"], multi["case"]
reference = runpy.run_path(str(HERE.parent / "Tests/AgentRuntimeTests/test_agentxd_multi_app.py"))["TestMultiAppRuntime"]
legacy = dict(id="old", appID="alpha", instanceID="pi-alpha", prompt="old prompt", response="old reply",
              startedAt=0, status="completed", isRead=False, processEvidence={"reaped": True}, extension={"keep": None})


@contextmanager
def python_service(workspace, bundle, helper, *, env=None):
    root = workspace / "root"
    args = [sys.executable, "-B", HERE.parent / "Tests/AgentRuntimeTests/agentxd_reference.py", "--root", root,
            "--pi-bundle", bundle, "--audit-helper", helper]
    with subprocess.Popen(args, stderr=subprocess.PIPE, text=True, env=env) as process:
        try:
            yield process, case.wait_for_endpoint(root, process)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=12)
    case.assertEqual(process.returncode, 0)


def raw_request(endpoint, method, path, body, key=None):
    connection = http.client.HTTPConnection("127.0.0.1", endpoint["port"], timeout=5)
    headers = {"Authorization": "Bearer " + endpoint["token"], "Content-Type": "application/json"}
    if key is not None:
        headers["Idempotency-Key"] = key
    try:
        connection.request(method, path, body, headers)
        response = connection.getresponse()
        return response.status, json.load(response)
    finally:
        connection.close()


def verify(engine, workspace, bundle, server):
    root = multi["configure"](workspace, server.server_port)
    marker = root / ".agentxd-pilot.json"
    file = root / "apps/alpha/runs/old.json"
    multi["pilot"]["put"](file, legacy)
    original = file.read_bytes()
    if engine == "python":
        config = json.loads(marker.read_bytes())
        del config["writer"]
        multi["pilot"]["put"](marker, config)
        helper = reference.audit_helper(workspace / "test-audit-helper")
        def launch():
            return python_service(workspace, bundle, helper)
    else:
        exe, env = fixture["prepare_desktop"](workspace, bundle)
        def launch():
            return fixture["desktop"](exe, workspace, env)

    base = "/v1/apps/alpha/runs"
    path = base + "/old"
    read = {"expectedRevision": 0, "isRead": True}
    with launch() as (process, endpoint):
        def request(method, url, payload=None, authorized=True):
            return case.exchange(endpoint, method, url, payload, authorize=authorized)

        for method, suffix, body in [("GET", "", None), ("POST", "/stop", {}), ("PATCH", "", read)]:
            case.assertEqual(request(method, path + suffix, body, False), (401, {}))
            for absent in [base + "/missing", "/v1/apps/beta/runs/old"]:
                case.assertEqual(request(method, absent + suffix, body), (404, {}))
        case.assertEqual(request("GET", path), (200, dict(legacy, revision=0)))
        case.assertEqual(file.read_bytes(), original)
        case.assertEqual(request("POST", path + "/stop", {}), (409, {"error": "not_a_service_execution"}))
        case.assertEqual(request("POST", path + "/stop", {"extra": True}), (404, {}))
        for bad in [None, {}, dict(read, extra=1), dict(read, isRead=1), dict(read, expectedRevision=False),
                    dict(read, expectedRevision=0.0), dict(read, expectedRevision=-1),
                    dict(read, expectedRevision="0"), dict(read, padding="x"*1024)]:
            case.assertEqual(request("PATCH", path, bad), (400, {}), bad)
        case.assertEqual(file.read_bytes(), original)
        for body in [b'{"expectedRevision":0,"isRead":true,}', b'{"expectedRevision":0e0,"isRead":true}',
                     b' ' * 1024 + json.dumps(read).encode()]:
            case.assertEqual(raw_request(endpoint, "PATCH", path, body), (400, {}), body[:50])
        huge = dict(read, expectedRevision=10**25)
        case.assertEqual(request("PATCH", path, huge), (409, dict(legacy, revision=0)))
        case.assertEqual(raw_request(endpoint, "POST", path + "/stop", b'{', "valid"), (400, {}))
        with ThreadPoolExecutor(max_workers=2) as pool:
            outcomes = list(pool.map(lambda _: request("PATCH", path, read), range(2)))
        case.assertEqual(sorted(code for code, _ in outcomes), [200, 409])
        changed = outcomes[0][1]
        case.assertEqual(changed, outcomes[1][1])
        case.assertEqual((changed["revision"], changed["isRead"], changed["extension"]), (1, True, legacy["extension"]))
        frozen = file.read_bytes()
        case.assertEqual(request("PATCH", path, dict(read, expectedRevision=1)), (200, changed))
        case.assertEqual(request("PATCH", path, dict(read, isRead=False)), (409, changed))
        case.assertEqual(file.read_bytes(), frozen)
        code, unread = request("PATCH", path, {"expectedRevision": 1, "isRead": False})
        case.assertEqual((code, unread["revision"], unread["isRead"]), (200, 2, False))
        case.assertEqual(request("GET", path), (200, unread))

        code, run = multi["post"](endpoint, "alpha", "active", "alpha-1")
        case.assertEqual(code, 201)
        rid = run["id"]
        live = base + "/" + rid
        fixture["wait_for"](lambda: len(server.calls) == 1, process, "Pi reached isolated model")
        status, run = request("GET", live)
        case.assertEqual((status, run["status"]), (200, "running"))
        code, marked = request("PATCH", live, {"expectedRevision": run["revision"], "isRead": True})
        case.assertEqual((code, marked["isRead"], marked["revision"]), (200, True, run["revision"] + 1))
        for key in [None, "invalid key"]:
            case.assertEqual(raw_request(endpoint, "POST", live + "/stop", b"{}", key),
                             (400, {"error": "invalid_idempotency_key"}))
        case.assertEqual(request("POST", live.replace("/alpha/", "/beta/") + "/stop", {}), (404, {}))
        code, pending = request("POST", live + "/stop", {})
        case.assertEqual((code, pending["status"], pending["stopEvidence"], pending["isRead"]),
                         (202, "cancelling", "pending", True))
        case.assertGreater(pending["revision"], marked["revision"])
        case.assertEqual(pending["pilotStopKey"], hashlib.sha256(b"contract-fixture").hexdigest())
        code, again = request("POST", live + "/stop", {})
        case.assertIn(code, (200, 202))
        if code == 202:
            case.assertEqual(again, pending)
        def stopped():
            code, result = request("GET", live)
            return result if code == 200 and result["status"] == "cancelled" else None
        final = fixture["wait_for"](stopped, process, "confirmed cancellation")
        case.assertEqual((final["stopEvidence"], final["isRead"], final["stopRequestedAt"]),
                         ("confirmedExited", True, pending["stopRequestedAt"]))
        case.assertGreater(final["revision"], pending["revision"])
        if engine == "python":
            receipt = final["processEvidence"]
        else:
            receipt_path, = (root / "manager/pi-processes").glob("*.json")
            receipt = json.loads(receipt_path.read_bytes())
            case.assertEqual(receipt["runID"], rid)
        case.assertIs(receipt["reaped"], True)
        case.assertEqual(receipt["owner"]["pid"], process.pid)
        case.assertEqual(request("POST", live + "/stop", {}), (200, final))
        case.assertEqual(request("PATCH", live, {"expectedRevision": marked["revision"], "isRead": False}), (409, final))
        code, audit = request("GET", live + "/audit")
        case.assertEqual((code, audit["verified"]), (200, True))
        case.assertCountEqual([e["kind"] for e in audit["records"]],
                              ["model.request.started", "model.request.cancel_requested", "model.request.cancelled"])
    frozen = {p: p.read_bytes() for p in file.parent.glob("*.json")}
    with launch() as (_, endpoint):
        case.assertEqual(request("GET", path), (200, unread))
        case.assertEqual(request("GET", live), (200, final))
        case.assertEqual(multi["cli"](root, "alpha", "show", rid), final)
        case.assertEqual(multi["cli"](root, "alpha", "stop", rid), final)
        case.assertEqual(request("POST", live + "/stop"), (200, final))
    case.assertEqual(frozen, {p: p.read_bytes() for p in file.parent.glob("*.json")})
    case.assertEqual(len(server.calls), 1)
    return unread, rid


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pi_bundle", type=Path)
    args = parser.parse_args()
    results = []
    for engine in ("python", "desktop"):
        with tempfile.TemporaryDirectory(prefix="agentxd-pi-e2e-", dir="/private/tmp") as directory:
            with ThreadingHTTPServer(("127.0.0.1", 0), multi["Model"]) as server:
                server.calls, server.release, server.lock = [], threading.Event(), threading.Lock()
                threading.Thread(target=server.serve_forever, daemon=True).start()
                try:
                    results.append(verify(engine, Path(directory), args.pi_bundle, server))
                finally:
                    server.release.set()
                    server.shutdown()
        print("PASS:", engine, "lookup, CAS read flag, owned Pi stop, replay and restart", flush=True)
    case.assertEqual(*results)
    print("PASS: legacy snapshots and service run IDs match across implementations.")
