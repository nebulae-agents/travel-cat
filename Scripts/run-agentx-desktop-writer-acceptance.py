#!/usr/bin/env python3
"""Start the normal desktop twice against one isolated root and a local model."""
import argparse
import base64
from contextlib import contextmanager
import hashlib
import http.client
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import ThreadingHTTPServer

REPO = Path(__file__).resolve().parents[1]
pilot = runpy.run_path(str(REPO / "Scripts/run-agentx-pi-pilot-acceptance.py"))
contract = runpy.run_path(str(REPO / "Tests/AgentRuntimeTests/test_agentxd_api_contract.py"))
case = contract["TestAgentxdApiContract"]()


def wait_for(check, app, message):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if app.poll() is not None:
            raise RuntimeError(f"desktop exited {app.returncode} before {message}")
        result = check()
        if result:
            return result
        time.sleep(.1)
    raise RuntimeError(message)


@contextmanager
def desktop(exe, workspace, env, *, interrupt=False):
    endpoint = workspace / "root/.agentxd-endpoint.json"
    previous = endpoint.read_bytes() if endpoint.exists() else None
    log = workspace / "gui.log"
    with log.open("ab") as output, subprocess.Popen([exe], env=env, cwd=workspace,
                                                     stdout=output, stderr=output) as app:
        try:
            wait_for(lambda: endpoint.is_file() and endpoint.read_bytes() != previous, app, "ordinary desktop did not publish its run endpoint")
            yield app, json.loads(endpoint.read_bytes())
        finally:
            if app.poll() is None:
                app.terminate()
                try:
                    app.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    app.kill()
                    app.wait()
                    raise
    case.assertEqual(app.returncode, -signal.SIGKILL if interrupt else 0)
    if not interrupt:
        case.assertFalse(endpoint.exists())


def merged(workspace, app, run_id, status):
    def received():
        for line in (workspace / "gui.log").read_text(errors="replace").splitlines():
            if line.startswith("{"):
                item = json.loads(line)
                if (item.get("pid"), item.get("runID"), item.get("status")) == (app.pid, run_id, status):
                    return True
    wait_for(received, app, "desktop did not merge " + run_id)


def prepare_desktop(workspace, bundle):
    root = workspace / "root"
    exe = pilot["temporary_app"](workspace)
    contents = exe.parents[1]
    (contents / "Helpers").mkdir(exist_ok=True)
    (contents / "Helpers/PiAgent").symlink_to((bundle / "Contents/Helpers/PiAgent").resolve(strict=True))
    resources = contents / "Resources/PiAgent"
    resources.mkdir()
    shutil.copy2(REPO / "Runtime/PiAgent/runner.mjs", resources / "runner.mjs")
    (resources / "node_modules").symlink_to((bundle / "Contents/Resources/PiAgent/node_modules").resolve(strict=True))
    env = dict(os.environ, AGENTX_ROOT=str(root), AGENTX_HOST_DIRECTORY=str(workspace / "host"),
               AGENTX_ACCEPTANCE_AUDIT_KEY=base64.b64encode(os.urandom(32)).decode())
    return exe, env


def verify(workspace, bundle, server, interrupt):
    pilot["configure"](workspace, server.server_port)
    root = workspace / "root"
    marker = root / ".agentxd-pilot.json"
    legacy_marker = pilot["read"](marker)
    history = root / "apps/pilot/runs/previous.json"
    pilot["put"](history, {"id": "previous", "appID": "pilot", "instanceID": "pi", "prompt": "previous turn",
                           "status": "completed", "response": "previous reply", "isRead": True, "startedAt": 1,
                           "processEvidence": {"reaped": True}, "auditStatus": "committed"})
    original = history.read_bytes()
    exe, env = prepare_desktop(workspace, bundle)
    path = "/v1/apps/pilot/runs"
    post = {"instanceId": "pi", "prompt": pilot["PROMPT"]}
    with desktop(exe, workspace, env, interrupt=interrupt) as (app, endpoint):
        case.assertEqual(pilot["read"](marker), dict(legacy_marker, writer="desktop"))
        migrated_marker = marker.stat()
        case.assertEqual(pilot["cli"](workspace, "list"), [dict(json.loads(original), revision=0)])
        merged(workspace, app, "previous", "completed")
        status, run = case.exchange(endpoint, "POST", path, post)
        case.assertEqual(status, 201)
        digest = hashlib.sha256(b"contract-fixture").hexdigest()
        case.assertEqual(run["id"], str(uuid.uuid5(uuid.NAMESPACE_URL, "agentxd/pilot/" + digest)))
        case.assertTrue(server.accepted.wait(15), "Pi did not reach the fixture model")
        merged(workspace, app, run["id"], "running")
        first_pid = app.pid
        receipt_file, = (root / "manager/pi-processes").glob("*.json")
        first_receipt = json.loads(receipt_file.read_bytes())
        case.assertEqual(first_receipt["owner"]["pid"], first_pid)
        case.assertEqual(first_receipt["runID"], run["id"])
        child_pid = first_receipt["child"]["pid"]
        if interrupt:
            app.kill()
            case.assertEqual(app.wait(timeout=8), -signal.SIGKILL)
    file = history.parent / (run["id"] + ".json")
    prior = json.loads(file.read_bytes())
    expected = ("failed", "unverified") if interrupt else ("cancelled", "confirmedExited")
    case.assertEqual(prior["status"], "running" if interrupt else "cancelled")
    if interrupt:
        # Observe the orphan before starting another application process.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(.05)
        else:
            raise RuntimeError("Pi is still alive five seconds after its desktop owner died")
        # A temporarily inaccessible audit must leave the interrupted snapshot recoverable.
        unavailable = dict(env, AGENTX_ACCEPTANCE_AUDIT_KEY=base64.b64encode(os.urandom(32)).decode())
        with desktop(exe, workspace, unavailable) as (app, pending_endpoint):
            pending = json.loads(file.read_bytes())
            case.assertEqual((pending["status"], pending["stopEvidence"], pending["revision"]),
                             ("failed", "unverified", prior["revision"] + 1))
            case.assertIs(pending["desktopInterruptionAuditPending"], True)
            case.assertEqual(case.exchange(pending_endpoint, "POST", path, post), (200, pending))
            case.assertEqual(len(list((root / "audit/pilot").glob("*.event"))), 1)
    with desktop(exe, workspace, env) as (app, second):
        case.assertEqual((marker.stat().st_ino, marker.stat().st_mtime_ns),
                         (migrated_marker.st_ino, migrated_marker.st_mtime_ns))
        snapshot = file.read_bytes()
        result = json.loads(snapshot)
        case.assertEqual((result["status"], result.get("stopEvidence")), expected)
        code, batch = case.exchange(second, "GET", f"{path}/{run['id']}/events?after=0", None)
        case.assertEqual((code, batch["revision"]), (200, result["revision"]))
        case.assertEqual([event["revision"] for event in batch["events"]], list(range(1, result["revision"] + 1)))
        expected_kinds = ["created", "auditConfirmed", "updated", "auditConfirmed"]
        if not interrupt:
            expected_kinds.extend(["updated", "auditConfirmed"])
        case.assertEqual([event["kind"] for event in batch["events"]], expected_kinds)
        case.assertEqual(batch["events"][-1]["state"], expected[0])
        if interrupt:
            case.assertIs(result["requiresProcessReview"], True)
            case.assertEqual(result["revision"], pending["revision"] + 1)
            case.assertNotIn("desktopInterruptionAuditPending", result)
            case.assertNotIn("auditFailure", result)
            connection = http.client.HTTPConnection("127.0.0.1", second["port"], timeout=5)
            try:
                connection.request("POST", path, json.dumps(post), {"Authorization": "Bearer " + second["token"],
                                   "Idempotency-Key": "different-key", "Content-Type": "application/json"})
                case.assertEqual(connection.getresponse().status, 409)
            finally:
                connection.close()
        case.assertNotEqual(first_pid, app.pid)
        case.assertNotEqual(endpoint["token"], second["token"])
        case.assertEqual(case.exchange(dict(second, token=endpoint["token"]), "GET", path, None)[0], 401)
        merged(workspace, app, "previous", "completed")
        merged(workspace, app, run["id"], expected[0])
        rows = {r["id"]: r for r in pilot["cli"](workspace, "list")}
        case.assertEqual(rows, {"previous": dict(json.loads(original), revision=0), run["id"]: result})
        case.assertEqual(case.exchange(second, "POST", path, post), (200, result))
        case.assertEqual(case.exchange(second, "POST", path, dict(post, prompt="different"))[0], 409)
    if interrupt:
        audit_files = sorted((root / "audit/pilot").glob("*.event"))
        case.assertEqual(len(audit_files), 2)
        events = [p.read_bytes() for p in audit_files]
        with desktop(exe, workspace, env) as (app, third):
            case.assertEqual(case.exchange(third, "POST", path, post), (200, result))
        case.assertEqual([p.read_bytes() for p in sorted((root / "audit/pilot").glob("*.event"))], events)
    # After quit, rejection must come from retirement or persisted ownership, not the root lock.
    for entry, reason in (("Runtime/agentxd.py", "retired"),
                          ("Tests/AgentRuntimeTests/agentxd_reference.py", "owned by the desktop")):
        refused = subprocess.run([sys.executable, "-B", REPO / entry, "--root", root],
                                 capture_output=True, text=True, timeout=6)
        case.assertNotEqual(refused.returncode, 0)
        case.assertIn(reason, refused.stderr)
        case.assertFalse((root / ".agentxd-endpoint.json").exists())
    case.assertEqual(history.read_bytes(), original)
    case.assertEqual(file.read_bytes(), snapshot)
    case.assertEqual(len(list(history.parent.glob("*.json"))), 2)
    receipts = list((root / "manager/pi-processes").glob("*.json"))
    case.assertEqual(len(receipts), 1)
    receipt = json.loads(receipts[0].read_bytes())
    case.assertEqual((receipt["runID"], receipt["owner"]["pid"], receipt["reaped"]), (run["id"], first_pid, not interrupt))
    case.assertEqual(server.count, 1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pi_bundle", type=Path)
    parser.add_argument("--interrupt", action="store_true", help="kill only the launched fixture App during its Pi turn")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="agentxd-pi-e2e-", dir="/private/tmp") as workspace:
        with ThreadingHTTPServer(("127.0.0.1", 0), pilot["StreamingModel"]) as server:
            server.accepted, server.done = threading.Event(), threading.Event()
            server.count_lock, server.count = threading.Lock(), 0
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                verify(Path(workspace), args.pi_bundle, server, args.interrupt)
            finally:
                server.done.set()
                server.shutdown()
    if args.interrupt:
        print("PASS: interrupted desktop, orphan Pi exited, failed/unverified restored, retries and audit stable across restart.")
    else:
        print("PASS: two normal desktop launches, history merged by both clients, one Pi execution, durable replay and conflict.")
