#!/usr/bin/env python3
"""Run the published run operations against the same isolated application fixtures."""
import argparse
from contextlib import contextmanager
import json
import hashlib
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer

HERE = Path(__file__).resolve().parent
replay = runpy.run_path(str(HERE / "run-agentx-desktop-event-replay-acceptance.py"))
controls, multi, fixture, case = (replay[k] for k in ("controls", "multi", "fixture", "case"))
BASE = "/v1/apps/{appId}/runs"
ONE = BASE + "/{runId}"
OPS = [("GET", BASE), ("POST", BASE), ("GET", ONE), ("PATCH", ONE), ("POST", ONE + "/stop"),
       ("GET", ONE + "/events"), ("GET", ONE + "/audit")]


@contextmanager
def unavailable_audit(root, app="alpha"):
    # Only move the synthetic journal in this temporary fixture.
    directory = root / "audit" / app
    saved = root / ("saved-audit-" + app)
    directory.rename(saved)
    try:
        directory.touch()
        yield
    finally:
        directory.unlink()
        saved.rename(directory)


def verify_audit_recovery(launch, root, model, body):
    base = BASE.format(appId="alpha")
    for phase in ("start", "complete", "stop"):
        model.release.clear()
        key = "fault-" + phase
        calls = len(model.calls)
        with launch() as (process, endpoint):
            def post(key, value, url=base):
                return controls["raw_request"](endpoint, "POST", url, json.dumps(value).encode(), key)
            def rows():
                return case.exchange(endpoint, "GET", base, None)[1]
            if phase != "start":
                code, run = post(key, body)
                case.assertEqual(code, 201)
                live = base + "/" + run["id"]
                fixture["wait_for"](lambda: len(model.calls) == calls + 1, process, "test model reached")
            with unavailable_audit(root):
                if phase == "start":
                    case.assertEqual(post(key, body), (503, {"error": "audit_unavailable"}))
                elif phase == "stop":
                    code, pending = post("stop", {}, live + "/stop")
                    case.assertEqual((code, pending["status"], pending["auditStatus"]), (202, "cancelling", "pending"))
                else:
                    model.release.set()
                digest = hashlib.sha256(key.encode()).hexdigest()
                def pending_result():
                    return next((r for r in rows() if r.get("pilotCreateKey") == digest and
                                r["status"] in ("completed", "cancelled", "failed") and r.get("auditStatus") == "pending"), None)
                pending = fixture["wait_for"](pending_result, process, "terminal result persisted despite audit failure")
                case.assertEqual(pending["status"], {"start":"failed", "complete":"completed", "stop":"cancelled"}[phase])
                if phase == "complete":
                    case.assertIn("reply alpha-1", pending["response"])
                case.assertEqual(post("while-pending-" + phase, body), (503, {"error": "audit_unavailable"}))
            model.release.set()
        live = base + "/" + pending["id"]
        with launch() as (_, endpoint):
            recovered = case.exchange(endpoint, "GET", live, None)[1]
            case.assertEqual((recovered["status"], recovered["response"], recovered["auditStatus"]),
                             (pending["status"], pending["response"], "confirmed"))
            report = case.exchange(endpoint, "GET", live + "/audit", None)[1]
            kinds = ["model.request.started"]
            if phase == "stop":
                kinds.append("model.request.cancel_requested")
            kinds.append("model.request." + recovered["status"])
            case.assertEqual([r["kind"] for r in report["records"]], kinds)
            case.assertTrue(report["verified"])
            case.assertEqual(post(key, body), (200, recovered))
        case.assertEqual(len(model.calls), calls + (phase != "start"))


def verify(engine, workspace, bundle, model):
    root = multi["configure"](workspace, model.server_port)
    put = multi["pilot"]["put"]
    marker = root / ".agentxd-pilot.json"
    config = json.loads(marker.read_bytes())
    del config["apps"][1]["pi"]
    if engine == "python":
        del config["writer"]
    put(marker, config)
    exe, env = fixture["prepare_desktop"](workspace, bundle)
    def launch():
        if engine == "desktop":
            return fixture["desktop"](exe, workspace, env)
        return controls["python_service"](workspace, bundle, exe, env=env)

    # Run the reference suite's original sparse-history assertions, unchanged.
    ref = controls["reference"]()
    ref.root = root
    ref.endpoint_file = root / ".agentxd-endpoint.json"
    ref.helper = exe
    @contextmanager
    def service():
        with launch() as (_, ref.endpoint):
            yield
    ref.service = service
    ref.test_same_run_id_stays_with_its_app_for_reads_events_and_updates()
    for app, name in (("alpha", "shared"), ("beta", "shared"), ("beta", "beta-only")):
        ref.run_path(app, name).unlink()
    # OpenAPI permits an identity-only snapshot. Its absent fields must stay absent.
    sparse = ref.run_path("alpha", "sparse")
    identity = {"id": "sparse", "appID": "alpha", "revision": 0}
    put(sparse, identity)
    before = sparse.read_bytes()
    with launch() as (_, endpoint):
        url = BASE.format(appId="alpha") + "/sparse"
        case.assertEqual(case.exchange(endpoint, "GET", url, None), (200, identity))
        case.assertEqual(sparse.read_bytes(), before)
        code, patched = case.exchange(endpoint, "PATCH", url, {"expectedRevision": 0, "isRead": False})
        case.assertEqual((code, patched["revision"], patched["events"][0]["state"]), (200, 1, "unknown"))
        case.assertNotIn("status", patched)
    sparse.unlink()
    for app in ("alpha", "beta"):
        put(root / f"apps/{app}/runs/shared.json",
            dict(controls["legacy"], id="shared", appID=app, instanceID="pi-" + app, response=app, prompt="fixture",
                 endedAt=1, stopEvidence="confirmedExited",
                 status="completed" if app == "alpha" else "failed"))
    # A valid prompt can still exceed the Pi limit once previous turns are included.
    put(root / "apps/alpha/runs/large.json", dict(controls["legacy"], id="large", response="x"*1_048_576))
    document = json.loads((HERE.parent / "api/agentxd.openapi.json").read_bytes())
    declared = {(m.upper(), path) for path, ops in document["paths"].items()
                for m in ops if m in {"get", "patch", "post"}}
    case.assertEqual(set(OPS) | {("GET", "/v1/apps/{appId}/runtime")}, declared)
    errors = []
    def match(label, actual, expected):
        if actual != expected:
            errors.append(f"{label}: expected {str(expected)[:160]}, received {str(actual)[:160]}")

    base = BASE.format(appId="alpha")
    other = BASE.format(appId="beta")
    body = {"instanceId": "pi-alpha", "prompt": "alpha-1"}
    def post(url, value, key):
        return controls["raw_request"](endpoint, "POST", url, json.dumps(value).encode(), key)

    binding = config["apps"][0]["pi"]
    address = binding["baseURL"]
    binding["baseURL"] = "https://127.0.0.1/v1"
    put(marker, config)
    with launch() as (_, endpoint):
        case.assertEqual(case.exchange(endpoint, "GET", base + "/shared", None)[0], 200)
        case.assertEqual(post(base, body, "invalid-config"), (422, {"error": "invalid_pi_configuration_or_context"}))
    binding["baseURL"] = address
    put(marker, config)
    beta_fixture = root / "apps/beta/runs/shared.json"
    original_beta = beta_fixture.read_bytes()
    with launch() as (_, endpoint):
        with unavailable_audit(root, "beta"):
            case.assert_published_contract(root, endpoint)
        match("large context", post(base, body, "oversize-context"),
              (422, {"error": "invalid_pi_configuration_or_context"}))
        match("large request does not create a run", len(case.exchange(endpoint, "GET", base, None)[1]), 2)
    beta_fixture.write_bytes(original_beta)
    (root / "apps/alpha/runs/large.json").unlink()
    # Keep an incomplete turn for the bound instance while issuing a new request.
    sparse_turn = ref.run_path("alpha", "sparse-turn")
    put(sparse_turn, dict(id="sparse-turn", appID="alpha", instanceID="pi-alpha", status="completed",
                          pilotCreateKey=hashlib.sha256(b"contract").hexdigest()))
    saved_turn = sparse_turn.read_bytes()
    with launch() as (process, endpoint):
        def get(path):
            return case.exchange(endpoint, "GET", path, None)
        for m, template in OPS:
            query = "?after=0" if template.endswith("/events") else ""
            url = template.format(appId="beta", runId="shared") + query
            match((m, template, "no auth"), case.exchange(endpoint, m, url, None, False), (401, {}))
            match((m, template, "app absent"), case.exchange(endpoint, m, url.replace("/beta/", "/absent/"), None), (404, {}))
        code, legacy_audit = get(base + "/sparse-turn/audit")
        match("legacy service snapshot", (code, legacy_audit.get("auditStatus")), (200, "legacy"))
        alpha_file = root / "apps/alpha/runs/shared.json"
        before = alpha_file.read_bytes()
        for app, url in [("alpha", base), ("beta", other)]:
            code, rows = get(url)
            case.assertEqual((code, [r["id"] for r in rows]),
                             (200, ["shared", "sparse-turn"] if app == "alpha" else ["shared"]))
            case.assertEqual(rows[0]["response"], app)
            case.assertEqual(get(url + "/shared"), (200, rows[0]))
        with replay["subscribe"](endpoint, other + "/shared", 0) as stream:
            code, changed = case.exchange(endpoint, "PATCH", other + "/shared", {"expectedRevision": 0, "isRead": True})
            case.assertEqual((code, changed["revision"]), (200, 1))
            event = json.loads(stream.recv(3))
            case.assertEqual(get(other + "/shared/events?after=0"), (200, {"revision": 1, "events": [event]}))
            case.assertEqual(case.exchange(endpoint, "PATCH", other + "/shared", {"expectedRevision": 0, "isRead": True}), (409, changed))
        case.assertEqual(get(base + "/shared/events?after=0"), (200, {"revision": 0, "events": []}))
        case.assertEqual(multi["cli"](root, "beta", "show", "shared"), changed)
        case.assertEqual(alpha_file.read_bytes(), before)
        case.assertEqual(post(other + "/shared/stop", {}, "stop"), (409, {"error": "not_a_service_execution"}))
        for value, key, status, reason in [(body, None, 400, "invalid_idempotency_key"),
                (dict(body, instanceId=5), "wrong-type", 400, "invalid_run"),
                (dict(body, instanceId=""), "empty-instance", 400, "invalid_run"),
                (dict(body, prompt=5), "invalid", 400, "invalid_run"), (dict(body, prompt=" "), "blank", 400, "invalid_run"),
                (dict(body, prompt="猫"*33334), "long", 400, "invalid_run"),
                (dict(body, instanceId="different"), "unbound", 422, "unbound_instance")]:
            match(reason, post(base, value, key), (status, {"error": reason}))
        match("no Pi", post(other, body, "unavailable"), (503, {"error": "pi_unavailable"}))
        match("legacy audit", get(other + "/shared/audit"), (200, dict(runId="shared", appID="beta",
              auditStatus="legacy", verified=True, chainRecords=0, records=[])))
        folder = alpha_file.parent
        mode = folder.stat().st_mode & 0o777
        folder.chmod(0o500)
        try:
            match("storage failure", case.exchange(endpoint, "PATCH", base + "/shared",
                  {"expectedRevision": 0, "isRead": True}), (500, {}))
        finally:
            folder.chmod(mode)
        case.assertEqual(alpha_file.read_bytes(), before)
        # A failed create must also yield a JSON storage error rather than a dropped connection.
        folder.chmod(0o500)
        try:
            match("create storage failure", post(base, body, "no-disk"), (500, {}))
        finally:
            folder.chmod(mode)
        match("malformed JSON", controls["raw_request"](endpoint, "POST", base, b'{"prompt":"bad",}', "bad"), (400, {}))
        code, created = post(base, body, "contract")
        case.assertEqual(code, 201)
        rid = created["id"]
        fixture["wait_for"](lambda: len(model.calls) == 1, process, "local model reached")
        messages = model.calls[0][1]
        case.assertEqual([m["role"] for m in messages if m["role"] != "system"], ["user", "assistant", "user"])
        case.assertEqual(sparse_turn.read_bytes(), saved_turn)
        live = base + "/" + rid
        case.assertEqual(post(base, body, "contract"), get(live))
        match("idempotency", post(base, dict(body, prompt="different"), "contract"), (409, {"error": "idempotency_conflict"}))
        match("busy", post(base, body, "busy"), (409, {"error": "instance_busy"}))
        code, cancelling = post(live + "/stop", {}, "stop")
        case.assertEqual((code, cancelling["stopEvidence"]), (202, "pending"))
        def stopped():
            _, result = get(live)
            return result if result["status"] == "cancelled" and result.get("auditStatus") != "pending" else None
        final = fixture["wait_for"](stopped, process, "confirmed stop")
        case.assertEqual(post(live + "/stop", {}, "stop"), (200, final))
        code, audit = get(live + "/audit")
        case.assertEqual((code, audit["verified"], audit["auditStatus"]), (200, True, "confirmed"))
        case.assertEqual([r["kind"] for r in audit["records"]], ["model.request.started",
                         "model.request.cancel_requested", "model.request.cancelled"])
        if engine == "desktop":
            for status in ("completed", "failed"):
                fixture["merged"](workspace, process, "shared", status)
            result = subprocess.run([sys.executable, "-B", HERE.parent/"Tests/AgentRuntimeTests/agentxd_reference.py", "--root", root],
                                    capture_output=True, timeout=8)
            case.assertNotEqual(result.returncode, 0)
            case.assertIn(b"pilot root already in use", result.stderr)
            case.assertEqual(get(live), (200, final))
    with launch() as (_, endpoint):
        case.assertEqual(get(live), (200, final))
        case.assertEqual(get(other + "/shared"), (200, changed))
    case.assertEqual(len(model.calls), 1)
    verify_audit_recovery(launch, root, model, body)
    # Simulate a lost acknowledgement after the encrypted append committed.
    # Only the test marker and synthetic snapshot change, with both writers stopped.
    directory = root / "audit/alpha"
    journal = {p.name: p.read_bytes() for p in directory.glob("*.event")}
    case.assertTrue(journal)
    receipt = root / f"apps/alpha/runs/{rid}.json"
    previous = json.loads(receipt.read_bytes())
    put(receipt, dict(previous, auditDelivered=0, auditStatus="pending"))
    if engine == "python":
        # The desktop must take over the reference writer's untouched legacy marker.
        successor = fixture["desktop"](exe, workspace, env)
    else:
        del config["writer"]
        successor = controls["python_service"](workspace, bundle, exe, env=env)
        put(marker, config)
    calls = len(model.calls)
    with successor as (_, endpoint):
        if engine == "python":
            case.assertEqual(json.loads(marker.read_bytes()), dict(config, writer="desktop"))
        code, transferred = get(live)
        case.assertEqual((code, transferred["auditStatus"], transferred["status"]), (200, "confirmed", "cancelled"))
        case.assertGreater(transferred["revision"], previous["revision"])
        case.assertEqual(post(base, body, "contract"), (200, transferred))
        code, verified = get(live + "/audit")
        case.assertEqual((code, verified["verified"], verified["records"]), (200, True, audit["records"]))
    case.assertEqual({p.name: p.read_bytes() for p in directory.glob("*.event")}, journal)
    case.assertEqual(len(model.calls), calls)
    if errors:
        raise AssertionError("\n".join(errors))
    # Process evidence may be tracked in a separate ledger. That can add a
    # running revision, so verify each cursor sequence, then compare lifecycle events.
    events = final["events"]
    case.assertEqual([e["revision"] for e in events], list(range(1, final["revision"] + 1)))
    lifecycle = [(e["kind"], e["state"]) for e in events if (e["kind"], e["state"]) != ("updated", "running")]
    case.assertEqual(lifecycle, [("created", "running"), ("auditConfirmed", "running"),
                                ("updated", "cancelling"), ("auditConfirmed", "cancelling"),
                                ("updated", "cancelled"), ("auditConfirmed", "cancelled")])
    return rid, event, final["stopEvidence"], lifecycle, [r["kind"] for r in audit["records"]]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pi_bundle", type=Path)
    args = parser.parse_args()
    results = []
    for engine in ("python", "desktop"):
        with tempfile.TemporaryDirectory(prefix="agentxd-pi-e2e-", dir="/private/tmp") as tmp:
            with ThreadingHTTPServer(("127.0.0.1", 0), multi["Model"]) as server:
                server.calls, server.release, server.lock = [], threading.Event(), threading.Lock()
                threading.Thread(target=server.serve_forever, daemon=True).start()
                try:
                    results.append(verify(engine, Path(tmp), args.pi_bundle, server))
                finally:
                    server.release.set()
                    server.shutdown()
        print("PASS:", engine, "7 operations, root/ID isolation, three audit faults and cross-writer acknowledgement replay", flush=True)
    case.assertEqual(*results)
