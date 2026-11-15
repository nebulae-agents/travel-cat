#!/usr/bin/env python3
"""Exercise a real Pi stop whose wait result is lost during an agentxd crash.

Run with --pi-bundle APP. Send the printed prompt in the isolated desktop.
After PENDING, inspect the window and create pending.seen in the printed workspace.
After RECOVERED READY, inspect the new window and create recovered.seen to finish.
"""
import argparse
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import ThreadingHTTPServer

HERE = Path(__file__).resolve()
spec = importlib.util.spec_from_file_location("agentx_acceptance", HERE.with_name("run-agentx-pi-pilot-acceptance.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
sys.path.insert(0, str(fixture.REPO / "Runtime"))
import agentxd
from agentxd_pi import PiProcess, _identity
from agentxd_runs import PilotRuns


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def wait_for(check, description, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(.1)
    raise RuntimeError("timeout: " + description)


def inspect_window(workspace, phase, app):
    def observed():
        require(app.poll() is None, "isolated desktop exited before window check")
        return (workspace / (phase + ".seen")).is_file()
    wait_for(observed, phase + " window observation", 1800)


def post_command(workspace, key, body, suffix=""):
    endpoint = fixture.read(workspace / "root/.agentxd-endpoint.json")
    connection = http.client.HTTPConnection("127.0.0.1", endpoint["port"], timeout=5)
    try:
        connection.request("POST", "/v1/apps/pilot/runs" + suffix, json.dumps(body), {
            "Authorization": "Bearer " + endpoint["token"], "Content-Type": "application/json",
            "Idempotency-Key": key,
        })
        response = connection.getresponse()
        return response.status, json.load(response)
    finally:
        connection.close()


def fault_service(workspace, bundle):
    """Hold only the real executor's return, after waitpid and before PilotRuns._patch."""
    root = workspace / "root"
    require(workspace.resolve() == workspace and workspace.parent == Path("/private/tmp")
            and workspace.name.startswith("agentxd-pi-e2e-") and workspace.stat().st_uid == os.getuid()
            and not workspace.stat().st_mode & 0o077 and not root.is_symlink()
            and fixture.read(root / ".agentxd-pilot.json")["root"] == str(root),
            "invalid isolated acceptance workspace")
    release = threading.Event()

    class AfterReap(PiProcess):
        def run(self, on_launch):
            result = super().run(on_launch)
            evidence = result.get("processEvidence", {})
            if result.get("status") == "cancelled" and evidence.get("reaped"):
                agentxd.write_json(workspace / "test-observed-reap.json", evidence)
                release.wait(1810)
            return result

    class ReceiptBarrier(PilotRuns):
        def __init__(self, store, pi_bundle):
            super().__init__(store, pi_bundle, AfterReap)

        def create(self, key, body):
            result = super().create(key, body)
            if result[0] == 201:
                agentxd.write_json(workspace / ".test-retry-key.json", key)
            return result

    def graceful_shutdown(_signum, _frame):
        release.set()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, graceful_shutdown)
    agentxd.PilotRuns = ReceiptBarrier
    agentxd.serve(root, pi_bundle=bundle)


def interrupted_turn(workspace, bundle, model, app, daemon):
    print("FIRST READY — send: " + fixture.PROMPT, flush=True)
    wait_for(model.accepted.is_set, "desktop Pi request", 1800)
    records = fixture.cli(workspace, "list")
    require(len(records) == 1 and records[0]["prompt"] == fixture.PROMPT,
            "expected a single desktop-created run")
    run_id = records[0]["id"]
    before = fixture.cli(workspace, "show", run_id)
    process = before["processEvidence"]
    pid = process["childPID"]
    require(before["status"] == "running" and before["runtimeCore"] == "pi-agent-core"
            and process["hostPID"] == daemon.pid and _identity(pid) == process["child"],
            "live process identity did not match the run")
    node = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "comm="], text=True).strip()
    require(Path(node).resolve() == (bundle / "Contents/Helpers/PiAgent/node").resolve(),
            "run is not using the packaged Pi Node")
    pending = fixture.cli(workspace, "stop", run_id)
    run_file = workspace / "root/apps/pilot/runs" / (run_id + ".json")
    pending_bytes = run_file.read_bytes()
    require(pending == json.loads(pending_bytes) and pending["status"] == "cancelling"
            and pending["stopEvidence"] == "pending" and pending["revision"] == before["revision"] + 1
            and pending["processEvidence"] == process, "stop intent was not durably accepted")
    barrier = workspace / "test-observed-reap.json"
    wait_for(barrier.is_file, "Pi waitpid receipt before daemon commit")
    reaped = fixture.read(barrier)
    require(all(reaped.get(k) == process[k] for k in ("launchID", "child", "owner", "childPID", "hostPID"))
            and reaped.get("reaped") is True and type(reaped.get("exitCode")) is int,
            "out-of-band waitpid receipt does not match this launch")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise RuntimeError("Pi PID still present at the requested crash boundary")
    print(f"PENDING run={run_id} revision={pending['revision']}, Pi reaped externally; inspect window", flush=True)
    inspect_window(workspace, "pending", app)
    require(daemon.poll() is None and _identity(daemon.pid) == process["owner"]
            and run_file.read_bytes() == pending_bytes, "crash target or durable state changed")
    daemon.kill()  # The Popen we started, still owning this exact launch.
    require(daemon.wait(timeout=10) == -signal.SIGKILL, "test daemon did not exit by SIGKILL")
    require(run_file.read_bytes() == pending_bytes, "crashed daemon committed a terminal state")
    agentxd.write_json(workspace / "interruption-evidence.json", {
        "before": before, "pending": pending, "testObservedReap": reaped, "childAbsent": True,
        "pendingSHA256": hashlib.sha256(pending_bytes).hexdigest(), "node": node,
        "firstDesktopPID": app.pid, "interruptedDaemonPID": daemon.pid, "daemonReturnCode": daemon.returncode,
    })


def recovered_turn(workspace, model, app, daemon):
    prior = fixture.read(workspace / "interruption-evidence.json")
    pending = prior["pending"]
    run_id = pending["id"]
    require(app.pid != prior["firstDesktopPID"] and daemon.pid != prior["interruptedDaemonPID"],
            "expected fresh desktop and daemon processes")
    restored = fixture.cli(workspace, "show", run_id)
    require(restored["status"] == "failed" and restored["stopEvidence"] == "unverified"
            and restored["requiresProcessReview"] is True and restored["revision"] == pending["revision"] + 1
            and restored["processEvidence"] == pending["processEvidence"]
            and "exitCode" not in restored["processEvidence"] and not restored["processEvidence"]["reaped"]
            and restored["stopRequestedAt"] == pending["stopRequestedAt"], "incorrect restart evidence")
    run_file = workspace / "root/apps/pilot/runs" / (run_id + ".json")
    baseline = (run_file.read_bytes(), run_file.stat().st_mtime_ns)
    require(json.loads(baseline[0]) == restored, "CLI disagrees with recovered file")
    body = {"instanceId": pending["instanceID"], "prompt": pending["prompt"]}
    key_file = workspace / ".test-retry-key.json"
    original_key = fixture.read(key_file)
    require(hashlib.sha256(original_key.encode()).hexdigest() == pending["pilotCreateKey"],
            "test key does not match the create request")
    same_code, same = post_command(workspace, original_key, body)
    mismatch = post_command(workspace, original_key, dict(body, prompt="another request"))
    new = post_command(workspace, str(uuid.uuid4()), body)
    require((same_code, same) == (200, restored), "same-key replay did not return the recovered run")
    require(mismatch == (409, {"error": "idempotency_conflict"}), "changed input reused a key")
    require(new == (409, {"error": "instance_busy"}), "unverified instance accepted new work")
    stop_code, stop_body = post_command(workspace, str(uuid.uuid4()), {}, "/" + run_id + "/stop")
    require((stop_code, stop_body) == (200, restored), "repeat stop did not return the recovered record")
    require(fixture.cli(workspace, "stop", run_id) == restored, "CLI repeat stop changed recovered run")
    require(fixture.cli(workspace, "list") == [restored], "unexpected extra run")
    require(baseline == (run_file.read_bytes(), run_file.stat().st_mtime_ns), "retries rewrote run file")
    key_file.unlink()
    observed = {}
    def desktop_merged():
        for line in (workspace / "gui.log").read_text(errors="replace").splitlines():
            if line.startswith("{"):
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if (row.get("pid") == app.pid and row.get("runID") == run_id
                        and row.get("status") == restored["status"] and row.get("stopEvidence") == "unverified"
                        and row.get("revision") == restored["revision"]):
                    observed.update(row)
                    return True
        return False
    wait_for(desktop_merged, "new desktop to decode and merge recovered CLI state")
    print(f"RECOVERED READY run={run_id} failed/unverified r{restored['revision']}; inspect window", flush=True)
    inspect_window(workspace, "recovered", app)
    require(model.count == 1 and fixture.cli(workspace, "show", run_id) == restored,
            "model activity or recovered run changed")
    agentxd.write_json(workspace / "recovery-evidence.json", {
        "restored": restored, "desktop": observed, "appPID": app.pid, "daemonPID": daemon.pid,
        "sameKeyStatus": same_code, "conflictingInput": list(mismatch), "newKey": list(new),
        "repeatStopStatus": stop_code, "repeatStopUnchanged": True,
        "unchangedBytesAndMtime": True, "modelRequests": model.count,
    })


def rehearse(bundle):
    workspace = Path(tempfile.mkdtemp(prefix="agentxd-pi-e2e-", dir="/private/tmp"))
    with ThreadingHTTPServer(("127.0.0.1", 0), fixture.StreamingModel) as model:
        model.accepted = threading.Event()
        model.done = threading.Event()
        model.count_lock = threading.Lock()
        model.count = 0
        fixture.configure(workspace, model.server_port)
        thread = threading.Thread(target=model.serve_forever, daemon=True)
        thread.start()
        print("WORKSPACE=" + str(workspace), flush=True)
        try:
            command = [sys.executable, "-B", str(HERE), "--barrier-workspace", str(workspace),
                       "--pi-bundle", str(bundle)]
            fixture.launch(workspace, bundle, daemon_args=command,
                           inspect=lambda app, daemon: interrupted_turn(workspace, bundle, model, app, daemon))
            fixture.launch(workspace, bundle,
                           inspect=lambda app, daemon: recovered_turn(workspace, model, app, daemon))
        finally:
            (workspace / ".test-retry-key.json").unlink(missing_ok=True)
            model.done.set()
            model.shutdown()
            thread.join()
    require(not (workspace / "root/.agentxd-endpoint.json").exists(), "service endpoint still present")
    print("PASS one Pi request; both desktops and daemons stopped; private evidence at " + str(workspace), flush=True)


if __name__ == "__main__":
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pi-bundle", type=Path, required=True)
    parser.add_argument("--barrier-workspace", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.barrier_workspace:
        fault_service(args.barrier_workspace, args.pi_bundle.resolve(strict=True))
    else:
        rehearse(args.pi_bundle.resolve(strict=True))
