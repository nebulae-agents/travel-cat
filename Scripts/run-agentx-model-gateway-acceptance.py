#!/usr/bin/env python3
"""Verify desktop -> disposable gateway -> local SSE with real Pi and isolated data."""
import argparse
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import runpy
import select
import tempfile
import threading
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
multi = runpy.run_path(str(HERE / "run-agentx-desktop-multi-app-acceptance.py"))
fixture, case = multi["fixture"], multi["case"]
SECRET = "agentx-gateway-fixture-credential"

class Model(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        prompt = body["messages"][-1]["content"]
        if isinstance(prompt, list): prompt = "".join(part.get("text", "") for part in prompt)
        self.server.calls.append((prompt, self.headers.get("Authorization"), body))
        if self.headers.get("Authorization") != "Bearer " + SECRET:
            self.send_response(401); self.end_headers(); return
        if prompt == "error":
            self.send_response(500); self.end_headers(); self.wfile.write(SECRET.encode()); return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        def chunk(choices, **extra):
            data = json.dumps(dict(choices=choices, **extra), ensure_ascii=False).encode()
            # Split a Unicode scalar between network writes.
            frame = b"data: " + data + b"\n\n"
            for start in range(0, len(frame), 7):
                self.wfile.write(frame[start:start+7]); self.wfile.flush()
        try:
            chunk([dict(index=0, delta=dict(content="猫🐾 first "), finish_reason=None)])
            if prompt == "usage-failure":
                chunk([], usage=dict(prompt_tokens=17, completion_tokens=2))
                self.wfile.write(b"data: not-json\n\n"); self.wfile.flush(); return
            if prompt in ("alpha-1", "timeout"):
                for _ in range(150):
                    ready, _, _ = select.select([self.connection], [], [], 0.1)
                    if ready and not self.connection.recv(1):
                        self.server.disconnected.set(); self.server.disconnections.append(prompt); return
                return
            for text in ("agentx-gateway-", "fixture-credential", " done"):
                chunk([dict(index=0, delta=dict(content=text), finish_reason=None)])
            chunk([dict(index=0, delta={}, finish_reason="stop")])
            if prompt in ("beta-1", "bad-tail"): chunk([], usage=dict(prompt_tokens=11, completion_tokens=3))
            if prompt == "bad-tail": chunk([dict(index=0, delta=dict(content="unexpected tail"), finish_reason=None)])
            self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError): self.server.disconnected.set()

def verify(workspace, bundle, server):
    root = multi["configure"](workspace, server.server_port)
    put = multi["pilot"]["put"]
    marker = root / ".agentxd-pilot.json"
    config = json.loads(marker.read_bytes())
    for app in config["apps"]: app["runStore"] = "events-v1"
    put(marker, config)
    put(root / "manager/gateway.yaml", dict(version=1, applications={app: dict(provider="local", model="fixture",
        max_output_tokens=23, max_request_bytes=1048576, timeout_seconds=20) for app in ("alpha", "beta")}))
    exe, env = fixture["prepare_desktop"](workspace, bundle)
    env["AGENTX_ACCEPTANCE_GATEWAY"] = "1"
    resources = exe.parents[1] / "Resources/PiAgent"
    (resources / "runner.mjs").rename(resources / "gateway-runner.mjs")
    captures = workspace / "stdin"; captures.mkdir()
    (resources / "runner.mjs").write_text("import {writeFileSync} from 'node:fs';\n" +
        "const original=process.stdin[Symbol.asyncIterator].bind(process.stdin);\n" +
        "process.stdin[Symbol.asyncIterator]=async function*(){const chunks=[];for await(const chunk of original()){chunks.push(chunk);yield chunk;}" +
        "writeFileSync(" + json.dumps(str(captures)) + "+'/' +process.pid+'.json',Buffer.concat(chunks));};\n" +
        "await import('./gateway-runner.mjs');\n")
    wait = fixture["wait_for"]
    rows = {}
    def get(endpoint, app, run):
        status, row = case.exchange(endpoint, "GET", f"/v1/apps/{app}/runs/{run}", None)
        case.assertEqual(status, 200)
        return row
    with fixture["desktop"](exe, workspace, env) as (process, endpoint):
        # Beta completion proves credential handoff and split-frame SSE first.
        code, beta = multi["post"](endpoint, "beta", "beta-1", "beta-1")
        case.assertEqual(code, 201)
        def terminal(app, run):
            row = get(endpoint, app, run)
            return row if row["status"] in ("completed", "failed", "cancelled") and row.get("auditStatus") == "confirmed" else None
        beta = wait(lambda: terminal("beta", beta["id"]), process, "gateway beta terminal")
        case.assertEqual(beta["status"], "completed")
        case.assertEqual(beta["response"], "猫🐾 first [redacted] done")
        case.assertEqual(beta["usage"], dict(inputTokens=11, outputTokens=3))
        case.assertEqual(beta["usageStatus"], "reported")
        rows["beta-1"] = beta
        code, alpha = multi["post"](endpoint, "alpha", "alpha-1", "alpha-1")
        case.assertEqual(code, 201)
        wait(lambda: get(endpoint, "alpha", alpha["id"])["response"] == "猫🐾 first ", process, "live gateway text")
        captured = next(json.loads(file.read_bytes()) for file in captures.glob("*.json") if "/apps/alpha/" in json.loads(file.read_bytes())["baseURL"])
        parsed = urlsplit(captured["baseURL"])
        gateway = dict(port=parsed.port, token=captured["gatewayToken"])
        request = dict(model="fixture", stream=True, messages=[dict(role="user", content="unexpected-reuse")])
        case.assertEqual(case.exchange(gateway, "POST", parsed.path + "/chat/completions", request)[0], 401)
        case.assertEqual(case.exchange(gateway, "POST", parsed.path.replace("alpha", "beta") + "/chat/completions", request)[0], 401)
        # Beta remains usable while alpha's stream is deliberately held open.
        code, other = multi["post"](endpoint, "beta", "beta-2", "beta-2")
        case.assertEqual(code, 201)
        other = wait(lambda: terminal("beta", other["id"]), process, "concurrent beta completion")
        case.assertEqual(other["status"], "completed")
        case.assertEqual(other["usageStatus"], "unknown")
        case.assertNotIn("usage", other)
        case.assertEqual(get(endpoint, "alpha", alpha["id"])["status"], "running")
        rows["beta-2"] = other
        path = f"/v1/apps/alpha/runs/{alpha['id']}/stop"
        case.assertEqual(case.exchange(endpoint, "POST", path, {})[0], 202)
        alpha = wait(lambda: terminal("alpha", alpha["id"]), process, "gateway cancellation")
        case.assertEqual((alpha["status"], alpha["response"], alpha["stopEvidence"]), ("cancelled", "猫🐾 first ", "confirmedExited"))
        wait(lambda: server.disconnected.is_set(), process, "upstream cancellation")
        rows["alpha-1"] = alpha
        for prompt in ("error", "usage-failure"):
            code, run = multi["post"](endpoint, "beta", prompt, prompt)
            case.assertEqual(code, 201)
            run = wait(lambda: terminal("beta", run["id"]), process, "gateway " + prompt)
            case.assertEqual(run["status"], "failed")
            if prompt == "usage-failure":
                case.assertEqual(run["usageStatus"], "reported")
                case.assertEqual(run["usage"], dict(inputTokens=17, outputTokens=2))
            else:
                case.assertEqual(run["usageStatus"], "unknown")
                case.assertNotIn("usage", run)
            case.assertNotIn(SECRET, json.dumps(run))
            rows[prompt] = run
        gateway_file = root / "manager/gateway.yaml"
        original = gateway_file.read_bytes()
        configuration = json.loads(original)
        configuration["applications"]["beta"]["timeout_seconds"] = 2
        put(gateway_file, configuration)
        try:
            code, timed = multi["post"](endpoint, "beta", "timeout", "timeout")
            case.assertEqual(code, 201)
            timed = wait(lambda: terminal("beta", timed["id"]), process, "gateway deadline")
            case.assertEqual((timed["status"], timed["stopEvidence"], timed["usageStatus"]), ("failed", "confirmedExited", "unknown"))
            wait(lambda: "timeout" in server.disconnections, process, "timed upstream closed")
            rows["timeout"] = timed
        finally: gateway_file.write_bytes(original)
        contract = runpy.run_path(str(HERE / "run-agentx-desktop-contract-acceptance.py"))
        calls = len(server.calls)
        with contract["unavailable_audit"](root):
            case.assertEqual(multi["post"](endpoint, "alpha", "audit-fault", "audit-fault")[0], 503)
        case.assertEqual(len(server.calls), calls)
        audit_fault = next(row for row in multi["cli"](root, "alpha", "list") if row["prompt"] == "audit-fault")
        case.assertEqual((audit_fault["status"], audit_fault["auditStatus"]), ("failed", "pending"))
        for key, row in rows.items():
            app = row["appID"]
            case.assertEqual(multi["post"](endpoint, app, key, key), (200, row))
            audit = multi["cli"](root, app, "audit", row["id"])
            case.assertTrue(audit["verified"])
            case.assertEqual(audit["auditStatus"], "confirmed")
    # The failed start deliberately has pending audit delivery. Its recovery may
    # append audit files and update its own snapshot, but no previous file may change.
    frozen = {path: data for path, data in multi["snapshot"](root, ["alpha", "beta"]).items() if path.stem != audit_fault["id"]}
    with fixture["desktop"](exe, workspace, env) as (_, endpoint):
        for key, row in rows.items(): case.assertEqual(multi["post"](endpoint, row["appID"], key, key), (200, row))
        code, recovered = multi["post"](endpoint, "alpha", "audit-fault", "audit-fault")
        case.assertEqual((code, recovered["status"], recovered["auditStatus"]), (200, "failed", "confirmed"))
    after = multi["snapshot"](root, ["alpha", "beta"])
    case.assertTrue(all(after.get(path) == data for path, data in frozen.items()))
    with fixture["desktop"](exe, workspace, env) as (_, endpoint):
        case.assertEqual(multi["post"](endpoint, "alpha", "audit-fault", "audit-fault"), (200, recovered))
    case.assertEqual(after, multi["snapshot"](root, ["alpha", "beta"]))
    case.assertEqual(Counter(prompt for prompt, _, _ in server.calls), {key: 1 for key in rows})
    for _, auth, body in server.calls:
        case.assertEqual(auth, "Bearer " + SECRET)
        case.assertEqual(body["max_tokens"], 23)
        case.assertEqual(body["model"], "fixture")
        case.assertNotIn("tools", body)
    inputs = list(captures.glob("*.json"))
    case.assertEqual(len(inputs), 6)
    for file in inputs:
        payload = json.loads(file.read_bytes())
        case.assertEqual(payload["secret"], "")
        case.assertNotIn(SECRET, file.read_text())
        case.assertEqual(len(payload["gatewayToken"]), 72)
        case.assertNotIn(f":{server.server_port}/", payload["baseURL"])
    for file in root.rglob("*"):
        if file.is_file(): case.assertNotIn(SECRET.encode(), file.read_bytes())

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pi_bundle", type=Path)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
    server.calls = []; server.disconnected = threading.Event(); server.disconnections = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="agentxd-pi-e2e-gateway-", dir="/private/tmp") as directory:
            verify(Path(directory), args.pi_bundle, server)
        print("PASS: gateway secret isolation, streaming, cancellation, usage, errors and restart idempotency")
    finally: server.shutdown(); server.server_close()
