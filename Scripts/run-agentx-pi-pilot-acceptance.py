#!/usr/bin/env python3
"""prepare, launch, and verify the native desktop -> real Pi -> CLI stop pilot.

Keep 'prepare' running. Run 'launch WORKSPACE --pi-bundle APP' in another terminal.
Send the printed prompt in the desktop. After cli-evidence.json appears, inspect the
desktop receipt, quit normally, run launch again, and use 'verify WORKSPACE'.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


REPO = Path(__file__).resolve().parents[1]
MODEL = "pilot-model"
PROMPT = "Pi stop acceptance"
SYSTEM = "Use this isolated Pi runtime for the local cancellation rehearsal."


def put(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2))


def read(path):
    return json.loads(path.read_bytes())


def configure(workspace, port):
    root = workspace / "root"
    root.mkdir(mode=0o700)
    app = root / "apps/pilot"
    (app / "runs").mkdir(parents=True)
    put(root / "agentx.yaml", {"version": 1, "current_app": "pilot", "blackcat": {"enabled": False}})
    put(app / "app.yaml", {"id": "pilot", "name": "Pi 运行验收", "kind": "chat", "enabled": True})
    base = "http://127.0.0.1:%d/v1" % port
    put(root / "manager/providers/local.yaml", {"name": "local", "base_url": base, "models": [{"id": MODEL}]})
    definition = root / "manager/templates/assistant/text"
    put(definition / "definition.yaml", {"id": "text", "name": "Pi 文本"})
    (definition / "agent.md").write_text(SYSTEM)
    put(app / "instances/pi/config/agent.yaml", {"id": "pi", "appID": "pilot", "name": "Pi 验收实例",
        "definitionID": "text", "providerID": "local", "model": MODEL})
    put(root / ".agentxd-pilot.json", {"root": str(root), "appID": "pilot", "pi": {
        "instanceID": "pi", "baseURL": base, "model": MODEL, "providerID": "local", "systemPrompt": SYSTEM}})


def cli(workspace, command, run_id=None):
    args = [str(REPO / "Scripts/agentx"), "--root", str(workspace / "root"), "run", command, "--app", "pilot"]
    if run_id is not None:
        args += ["--run", run_id]
    return json.loads(subprocess.check_output(args, timeout=45))


class StreamingModel(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if self.path != "/v1/chat/completions" or not 0 < length < 1048576:
            return self.send_error(400)
        request = json.loads(self.rfile.read(length))
        messages = request.get("messages") or []
        if request.get("model") != MODEL or request.get("stream") is not True or not messages:
            return self.send_error(400)
        text = messages[-1].get("content")
        if isinstance(text, list):
            text = "".join(x.get("text", "") for x in text if isinstance(x, dict))
        if messages[-1].get("role") != "user" or text != PROMPT:
            return self.send_error(422)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        frame = {"id": "pilot-acceptance", "object": "chat.completion.chunk",
                 "choices": [{"index": 0, "delta": {"role": "assistant", "content": "ready"}, "finish_reason": None}]}
        try:
            self.wfile.write(("data: " + json.dumps(frame) + "\n\n").encode())
            self.wfile.flush()
            with self.server.count_lock:
                self.server.count += 1
            self.server.accepted.set()
            while not self.server.done.wait(0.2):
                self.wfile.write(b": waiting for CLI stop\n\n")
                self.wfile.flush()
        except (ConnectionError, OSError):
            pass


def capture(workspace):
    records = cli(workspace, "list")
    if len(records) != 1 or records[0].get("prompt") != PROMPT:
        raise RuntimeError("expected exactly one desktop-created acceptance run")
    run_id = records[0]["id"]
    before = cli(workspace, "show", run_id)
    process = before.get("processEvidence") or {}
    if before["status"] != "running" or before.get("runtimeCore") != "pi-agent-core":
        raise RuntimeError("CLI did not see a live Pi run")
    pid = process["childPID"]
    node = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "comm="], text=True).strip()
    if Path(node).resolve() != Path(read(workspace / "runtime.json")["node"]).resolve():
        raise RuntimeError("observed process does not match bundled Pi Node")
    stopped = cli(workspace, "stop", run_id)
    for _ in range(100):
        final = cli(workspace, "show", run_id)
        if final.get("stopEvidence") == "confirmedExited":
            break
        time.sleep(.1)
    receipt = final.get("processEvidence") or {}
    if (final["status"] != "cancelled" or final.get("stopEvidence") != "confirmedExited"
            or receipt.get("childPID") != pid or receipt.get("launchID") != process["launchID"]
            or not receipt.get("reaped") or type(receipt.get("exitCode")) is not int
            or not before["revision"] < stopped["revision"] <= final["revision"]):
        raise RuntimeError("CLI did not receive matching process-exit evidence")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise RuntimeError("child PID is still present after confirmed exit")
    put(workspace / "cli-evidence.json", {"before": before, "stop": stopped, "terminal": final,
        "node": node, "childPIDAbsentAfterStop": True, "streamReceived": True})
    print("CLI observed and stopped " + run_id + "; terminal receipt saved", flush=True)


def prepare():
    workspace = Path(tempfile.mkdtemp(prefix="agentxd-pi-e2e-", dir="/private/tmp"))
    with ThreadingHTTPServer(("127.0.0.1", 0), StreamingModel) as server:
        server.accepted = threading.Event()
        server.done = threading.Event()
        server.count_lock = threading.Lock()
        server.count = 0
        configure(workspace, server.server_port)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        print("WORKSPACE=" + str(workspace) + "\nDESKTOP PROMPT=" + PROMPT, flush=True)
        try:
            if not server.accepted.wait(1800):
                raise RuntimeError("no desktop Pi model request arrived in 30 minutes")
            capture(workspace)
            deadline = time.monotonic() + 1800
            while not (workspace / "restart-evidence.json").exists():
                if time.monotonic() > deadline:
                    raise RuntimeError("timed out waiting for restart verification")
                time.sleep(.25)
            with server.count_lock:
                if server.count != 1:
                    raise RuntimeError("expected exactly one accepted model request across both launches")
                print("Accepted model requests across restart:", server.count, flush=True)
        finally:
            server.done.set()
            server.shutdown()
            thread.join()


def temporary_app(workspace):
    scratch = subprocess.check_output([str(REPO / "Scripts/travel-cat-swift.sh"), "scratch-path"], text=True).strip()
    products = Path(scratch) / "debug"
    app = workspace / "AgentX Pi Run Acceptance.app"
    exe = app / "Contents/MacOS/TravelCatApp"
    root = workspace / "root"
    info_file = app / "Contents/Info.plist"
    if (workspace.resolve() != workspace or workspace.parent != Path("/private/tmp")
            or not workspace.name.startswith("agentxd-pi-e2e-") or read(root / ".agentxd-pilot.json").get("root") != str(root)
            or exe.resolve() != exe or info_file.resolve() != info_file):
        raise RuntimeError("refusing to stage an application outside the isolated fixture")
    if app.exists():
        if (not exe.is_file() or not info_file.is_file()
                or plistlib.loads(info_file.read_bytes()).get("CFBundleIdentifier") != "local.agentx.pi-run.acceptance"):
            raise RuntimeError("unexpected existing application in fixture")
    else:
        exe.parent.mkdir(parents=True)
        resources = app / "Contents/Resources"
        resources.mkdir()
        shutil.copy2(products / "TravelCatApp", exe)
        for bundle in ("TravelCat_TravelUI.bundle", "TravelCat_TravelCatApp.bundle"):
            shutil.copytree(products / bundle, resources / bundle)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "local.agentx.pi-run.acceptance", "CFBundleName": "AgentX Pi Run Acceptance",
            "CFBundleDisplayName": "AgentX Pi Run Acceptance", "CFBundleExecutable": "TravelCatApp",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSMinimumSystemVersion": "14.0"}))
    # LaunchServices can reopen the bundle independently of the harness.
    # Configure that entry point too, including previously prepared test bundles.
    info = plistlib.loads(info_file.read_bytes())
    isolated = {"AGENTX_ROOT": str(workspace / "root"), "AGENTX_HOST_DIRECTORY": str(workspace / "host")}
    if info.get("LSEnvironment") != isolated:
        info["LSEnvironment"] = isolated
        info["CFBundleVersion"] = "2"
        with tempfile.NamedTemporaryFile(dir=info_file.parent, delete=False) as stream:
            stream.write(plistlib.dumps(info))
        os.replace(stream.name, info_file)
        os.utime(app, None)
    if plistlib.loads(info_file.read_bytes()).get("LSEnvironment") != isolated:
        raise RuntimeError("temporary bundle is missing its isolated LaunchServices environment")
    built = products / "TravelCatApp"
    current_hash = hashlib.sha256(exe.read_bytes()).hexdigest()
    build_hash = hashlib.sha256(built.read_bytes()).hexdigest()
    if current_hash != build_hash:
        # The prior binary remains available for comparison after the isolated build refresh.
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            fcntl.flock(root_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            lock_path = "/private/tmp/local.agentx.pi-run.acceptance.user-%d.desktop.lock" % os.getuid()
            holders = subprocess.run(["/usr/sbin/lsof", "-t", lock_path], capture_output=True, text=True)
            if holders.stdout.strip() or holders.returncode not in (0, 1):
                raise RuntimeError("test application still owns the single-instance lock")
            history = workspace / "build-history"
            if history.resolve() != history:
                raise RuntimeError("unexpected build history path")
            history.mkdir(exist_ok=True)
            previous = history / ("TravelCatApp-" + current_hash)
            if not previous.exists():
                os.link(exe, previous)
            with tempfile.NamedTemporaryFile(dir=exe.parent, delete=False) as stream:
                staged = Path(stream.name)
            shutil.copy2(built, staged)
            if hashlib.sha256(staged.read_bytes()).hexdigest() != build_hash:
                staged.unlink()
                raise RuntimeError("debug build changed during staging")
            os.replace(staged, exe)
            put(history / (current_hash + "-to-" + build_hash + ".json"), {
                "beforeSHA256": current_hash, "afterSHA256": build_hash, "savedPreviousExecutable": previous.name})
        finally:
            os.close(root_fd)
    return exe


def await_daemon_ready(endpoint, previous, daemon, *, timeout=75):
    # The service publishes its endpoint only after its bounded 60s audit handshake.
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if daemon.poll() is not None:
            raise RuntimeError("daemon startup failed")
        if endpoint.exists() and endpoint.read_bytes() != previous:
            return
        time.sleep(.05)
    raise RuntimeError("daemon readiness timed out")


def launch(workspace, bundle, *, daemon_args=None, inspect=None, audit_helper=None):
    exe = temporary_app(workspace)
    root = workspace / "root"
    node = bundle / "Contents/Helpers/PiAgent/node"
    if not node.is_file() or not (bundle / "Contents/Resources/PiAgent/runner.mjs").is_file():
        raise RuntimeError("expected an app with its packaged Pi runtime")
    put(workspace / "runtime.json", {"node": str(node.resolve())})
    endpoint = root / ".agentxd-endpoint.json"
    old = endpoint.read_bytes() if endpoint.exists() else None
    args = [sys.executable, "-B", str(REPO / "Runtime/agentxd.py"), "--root", str(root), "--pi-bundle", str(bundle),
            "--audit-helper", str((audit_helper or exe).resolve(strict=True))]
    daemon = subprocess.Popen(daemon_args if daemon_args is not None else args)
    try:
        await_daemon_ready(endpoint, old, daemon)
        with (workspace / "gui.log").open("a") as log:
            env = dict(os.environ, AGENTX_ROOT=str(root), AGENTX_HOST_DIRECTORY=str(workspace / "host"))
            app = subprocess.Popen([str(exe)], env=env, stdout=log, stderr=log)
            try:
                lock_path = "/private/tmp/local.agentx.pi-run.acceptance.user-%d.desktop.lock" % os.getuid()
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    if app.poll() is not None or daemon.poll() is not None:
                        raise RuntimeError("test client or daemon exited during startup; check the test bundle's single-instance lock")
                    holder = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(app.pid), "-t", lock_path],
                                            capture_output=True, text=True)
                    if str(app.pid) in holder.stdout.splitlines():
                        break
                    time.sleep(.2)
                else:
                    raise RuntimeError("test client did not acquire the expected single-instance lock")
                cli(workspace, "list")
                if app.poll() is not None or daemon.poll() is not None:
                    raise RuntimeError("test processes exited before readiness")
                put(workspace / "launch.json", {"appPID": app.pid, "daemonPID": daemon.pid})
                print(f"Ready: GUI pid={app.pid} daemon pid={daemon.pid}, client holds lock and service answered", flush=True)
                if inspect is not None:
                    inspect(app, daemon)
                else:
                    result = app.wait()
                    print(f"GUI pid={app.pid} exit={result}", flush=True)
            finally:
                if app.poll() is None:
                    app.terminate()
                    app.wait()
    finally:
        if daemon.poll() is None:
            daemon.terminate()
        daemon.wait()


def verify(workspace):
    terminal = read(workspace / "cli-evidence.json")["terminal"]
    restored = cli(workspace, "show", terminal["id"])
    if restored != terminal:
        raise RuntimeError("restored CLI record differs from the terminal receipt")
    active = read(workspace / "launch.json")
    if active["daemonPID"] == terminal["processEvidence"]["hostPID"]:
        raise RuntimeError("daemon has not restarted")
    # The debug-only desktop receipt is emitted after decoding and merging the service
    # response. Match the new PID to exclude old sessions in the append-only GUI log.
    expected = {"pid": active["appPID"], "runID": terminal["id"], "status": terminal["status"],
                "revision": terminal["revision"], "stopEvidence": terminal["stopEvidence"]}
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        for line in (workspace / "gui.log").read_text(errors="replace").splitlines():
            if not line.startswith("{"):
                continue
            try:
                item = json.loads(line)
            except ValueError:
                continue
            if isinstance(item, dict) and all(item.get(k) == v for k, v in expected.items()):
                put(workspace / "restart-evidence.json", {"restored": restored, "desktop": item, **active})
                break
        else:
            time.sleep(.1)
            continue
        break
    else:
        raise RuntimeError("new desktop process did not confirm the restored run")
    print(f'Restored {restored["id"]}: {restored["status"]}, {restored["stopEvidence"]}, revision {restored["revision"]}')


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    subs = parser.add_subparsers(dest="action", required=True)
    subs.add_parser("prepare")
    client = subs.add_parser("launch")
    client.add_argument("workspace", type=Path)
    client.add_argument("--pi-bundle", type=Path, required=True)
    client.add_argument("--audit-helper", type=Path, help="optional matching Swift helper (default: staged debug client)")
    subs.add_parser("verify").add_argument("workspace", type=Path)
    args = parser.parse_args()
    if args.action == "prepare":
        prepare()
    else:
        workspace = args.workspace.resolve(strict=True)
        if workspace.parent != Path("/private/tmp") or not workspace.name.startswith("agentxd-pi-e2e-"):
            parser.error("expected the workspace printed by prepare")
        if args.action == "launch":
            launch(workspace, args.pi_bundle.resolve(strict=True),
                   audit_helper=args.audit_helper.resolve(strict=True) if args.audit_helper else None)
        else:
            verify(workspace)
