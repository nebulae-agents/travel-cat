#!/usr/bin/env python3
"""Run two registered apps in one isolated desktop and interrupt only alpha's Pi."""
import argparse
from collections import Counter
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import tempfile
import threading

HERE = Path(__file__).resolve().parent
fixture = runpy.run_path(str(HERE / "run-agentx-desktop-writer-acceptance.py"))
pilot, case = fixture["pilot"], fixture["case"]
identity = runpy.run_path(str(HERE.parent / "Runtime/agentxd_pi.py"))["_identity"]


class Model(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = body["messages"]
        prompt = messages[-1]["content"]
        if isinstance(prompt, list):
            prompt = "".join(part.get("text", "") for part in prompt)
        if self.path != "/v1/chat/completions" or prompt not in ("alpha-1", "beta-1", "beta-2"):
            return self.send_error(400)
        with self.server.lock:
            self.server.calls.append((prompt, messages))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        if not self.server.release.wait(30):
            return
        chunks = [{"delta": {"content": "reply " + prompt}, "finish_reason": None},
                  {"delta": {}, "finish_reason": "stop"}]
        try:
            for choice in chunks:
                data = {"id": "fixture", "choices": [dict(choice, index=0)]}
                self.wfile.write(("data: " + json.dumps(data) + "\n\n").encode())
            self.wfile.write(b"data: [DONE]\n\n")
        except (BrokenPipeError, ConnectionResetError):
            pass


def configure(workspace, port):
    root = workspace / "root"
    root.mkdir(mode=0o700)
    put = pilot["put"]
    put(root / "agentx.yaml", {"version": 1, "current_app": "alpha", "blackcat": {"enabled": False}})
    base = f"http://127.0.0.1:{port}/v1"
    put(root / "manager/providers/local.yaml", {"name": "local", "base_url": base, "models": [{"id": "fixture"}]})
    definition = root / "manager/templates/assistant/text"
    put(definition / "definition.yaml", {"id": "text", "name": "text"})
    (definition / "agent.md").write_text("fixture")
    apps = []
    for name in ("alpha", "beta"):
        instance = "pi-" + name
        app = root / "apps" / name
        (app / "runs").mkdir(parents=True)
        put(app / "app.yaml", {"id": name, "name": name, "kind": "chat", "enabled": True})
        put(app / f"instances/{instance}/config/agent.yaml", {"id": instance, "appID": name, "name": instance,
            "definitionID": "text", "providerID": "local", "model": "fixture"})
        apps.append({"appID": name, "pi": {"instanceID": instance, "baseURL": base, "model": "fixture",
                    "providerID": "local", "systemPrompt": "system-" + name}})
    put(root / ".agentxd-pilot.json", {"root": str(root), "writer": "desktop", "version": 2, "apps": apps})
    return root


def post(endpoint, app, key, prompt):
    conn = http.client.HTTPConnection("127.0.0.1", endpoint["port"], timeout=5)
    try:
        conn.request("POST", f"/v1/apps/{app}/runs", json.dumps({"instanceId": "pi-" + app, "prompt": prompt}),
                     headers={"Authorization": "Bearer " + endpoint["token"], "Idempotency-Key": key,
                              "Content-Type": "application/json"})
        response = conn.getresponse()
        return response.status, json.load(response)
    finally:
        conn.close()


def cli(root, app, operation, run=None):
    args = [HERE / "agentx", "--root", root, "run", operation, "--app", app]
    if run is not None:
        args.extend(["--run", run])
    return json.loads(subprocess.check_output(args, timeout=8))


def snapshot(root, names):
    return {path: path.read_bytes() for name in names
            for folder in (root / "apps" / name / "runs", root / "audit" / name)
            for path in folder.iterdir() if path.suffix in (".json", ".event")}


def verify(workspace, bundle, server):
    root = configure(workspace, server.server_port)
    exe, env = fixture["prepare_desktop"](workspace, bundle)
    wait = fixture["wait_for"]
    snapshots = {}
    with fixture["desktop"](exe, workspace, env) as (app, endpoint):
        for name in ("alpha", "beta"):
            case.assertEqual(cli(root, name, "list"), [])
            status, run = post(endpoint, name, "shared", name + "-1")
            case.assertEqual(status, 201)
            case.assertEqual(run["appID"], name)
            snapshots[name] = run
            case.assertEqual(post(endpoint, name, "shared", name + "-1"), (200, run))
        case.assertNotEqual(snapshots["alpha"]["id"], snapshots["beta"]["id"])
        case.assertEqual(snapshots["alpha"]["pilotCreateKey"], snapshots["beta"]["pilotCreateKey"])
        wait(lambda: len(server.calls) == 2, app, "both independent Pi calls must overlap")
        receipts = [json.loads(p.read_bytes()) for p in (root / "manager/pi-processes").glob("*.json")]
        active = {r["runID"]: r for r in receipts}
        case.assertEqual(set(active), {r["id"] for r in snapshots.values()})
        receipt = active[snapshots["alpha"]["id"]]
        child = receipt["child"]["pid"]
        case.assertEqual(receipt["owner"], identity(app.pid))
        case.assertEqual(receipt["child"], identity(child))
        parent = subprocess.check_output(["/bin/ps", "-p", str(child), "-o", "ppid="], text=True)
        case.assertEqual(int(parent.strip()), app.pid)
        case.assertFalse(receipt["reaped"])
        os.kill(child, signal.SIGKILL)
        wait(lambda: cli(root, "alpha", "list")[0]["status"] == "failed", app, "alpha failure")
        case.assertEqual(cli(root, "beta", "list")[0]["status"], "running")
        alpha = cli(root, "alpha", "list")[0]
        case.assertEqual(alpha["stopEvidence"], "confirmedExited")
        frozen = snapshot(root, ["alpha"])
        server.release.set()
        wait(lambda: cli(root, "beta", "list")[0]["status"] == "completed", app, "beta completion")
        status, more = post(endpoint, "beta", "fresh", "beta-2")
        case.assertEqual(status, 201)
        def beta_finished():
            runs = cli(root, "beta", "list")
            return len(runs) == 2 and all(r["status"] == "completed" for r in runs)
        wait(beta_finished, app, "new beta work after alpha failure")
        case.assertEqual(snapshot(root, ["alpha"]), frozen)
        snapshots["alpha"] = alpha
        beta = {r["id"]: r for r in cli(root, "beta", "list")}
        snapshots["beta"] = beta[snapshots["beta"]["id"]]
        case.assertEqual(beta[more["id"]]["response"], "reply beta-2")
        case.assertEqual(snapshots["beta"]["response"], "reply beta-1")
        for name, other, terminal, chain in [("alpha", "beta", "failed", 2), ("beta", "alpha", "completed", 4)]:
            rid = snapshots[name]["id"]
            case.assertEqual(post(endpoint, name, "shared", "wrong")[0], 409)
            case.assertEqual(post(endpoint, name, "shared", name + "-1"), (200, snapshots[name]))
            audit = cli(root, name, "audit", rid)
            case.assertIs(audit["verified"], True)
            case.assertEqual(audit["chainRecords"], chain)
            case.assertEqual([r["kind"] for r in audit["records"]], ["model.request.started", "model.request." + terminal])
            case.assertTrue(all(r["appId"] == name and r["taskId"] == rid for r in audit["records"]))
            path = f"/v1/apps/{other}/runs/{rid}/audit"
            case.assertEqual(case.exchange(endpoint, "GET", path, None)[0], 404)
            case.assertEqual(audit["auditStatus"], "confirmed")
            own_path = f"/v1/apps/{name}/runs/{rid}/audit"
            case.assertEqual(case.exchange(endpoint, "GET", own_path, None, authorize=False)[0], 401)
        extra = cli(root, "beta", "audit", more["id"])
        case.assertEqual([r["taskId"] for r in extra["records"]], [more["id"], more["id"]])
        case.assertEqual([r["kind"] for r in extra["records"]], ["model.request.started", "model.request.completed"])
        case.assertTrue(all(r["appId"] == "beta" for r in extra["records"]))
        for r in [alpha, *beta.values()]:
            fixture["merged"](workspace, app, r["id"], r["status"])
    durable = snapshot(root, ["alpha", "beta"])
    case.assertEqual(len(durable), 9)
    with fixture["desktop"](exe, workspace, env) as (_, second):
        for name in ("alpha", "beta"):
            case.assertEqual(post(second, name, "shared", name + "-1"), (200, snapshots[name]))
            rows = cli(root, name, "list")
            expected = [alpha] if name == "alpha" else list(beta.values())
            case.assertEqual(sorted(rows, key=lambda r: r["id"]), sorted(expected, key=lambda r: r["id"]))
        case.assertEqual(post(second, "beta", "fresh", "beta-2"), (200, beta[more["id"]]))
    case.assertEqual(durable, snapshot(root, ["alpha", "beta"]))
    case.assertEqual(Counter(p for p, _ in server.calls), {"alpha-1": 1, "beta-1": 1, "beta-2": 1})
    for prompt, messages in server.calls:
        other = "alpha" if prompt.startswith("beta") else "beta"
        case.assertNotIn(other, json.dumps(messages))
    case.assertEqual(len(list((root / "manager/pi-processes").glob("*.json"))), 3)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pi_bundle", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="agentxd-pi-e2e-", dir="/private/tmp") as directory:
        with ThreadingHTTPServer(("127.0.0.1", 0), Model) as server:
            server.calls, server.release, server.lock = [], threading.Event(), threading.Lock()
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                verify(Path(directory), args.pi_bundle, server)
            finally:
                server.release.set()
                server.shutdown()
    print("PASS: two apps, three Pi executions, alpha interrupted, beta continued, independent retries and verified audit chains.")
