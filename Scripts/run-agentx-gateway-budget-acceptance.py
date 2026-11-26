#!/usr/bin/env python3
"""Verify a root-wide daily budget with real desktop/Pi and exclusively local fixtures."""
import argparse
from decimal import Decimal
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import runpy
import tempfile
import threading

HERE = Path(__file__).resolve().parent
gateway = runpy.run_path(str(HERE / "run-agentx-model-gateway-acceptance.py"))
multi, fixture, case = gateway["multi"], gateway["fixture"], gateway["case"]

def verify(workspace, bundle, server):
    root = multi["configure"](workspace, server.server_port)
    put = multi["pilot"]["put"]
    marker = root / ".agentxd-pilot.json"
    config = json.loads(marker.read_bytes())
    for app in config["apps"]: app["runStore"] = "events-v1"
    put(marker, config)
    provider_file = root / "manager/providers/local.yaml"
    provider = json.loads(provider_file.read_bytes())
    provider["models"][0].update(context_length=100, enabled=True)
    put(provider_file, provider)
    put(root / "manager/gateway.yaml", dict(version=1, applications={app: dict(provider="local", model="fixture",
        max_output_tokens=23, max_request_bytes=1048576, timeout_seconds=20) for app in ("alpha", "beta")}))
    budget_file = root / "manager/gateway-budget.yaml"
    policy = dict(version=1, currency="USD", time_zone="Asia/Shanghai", daily_limit="0.2", prices={"local": {"fixture": {
        "input_per_token": "0.001", "output_per_token": "0.002", "source": "local fixture, not market price", "revision": "v1"}}})
    put(budget_file, policy)
    exe, env = fixture["prepare_desktop"](workspace, bundle)
    env["AGENTX_ACCEPTANCE_GATEWAY"] = "1"
    wait = fixture["wait_for"]
    def terminal(process, endpoint, app, run):
        def read():
            code, row = case.exchange(endpoint, "GET", f"/v1/apps/{app}/runs/{run}", None)
            case.assertEqual(code, 200)
            return row if row["status"] in ("completed", "failed", "cancelled") and row.get("auditStatus") == "confirmed" else None
        return wait(read, process, "budget terminal")
    with fixture["desktop"](exe, workspace, env) as (process, endpoint):
        code, alpha = multi["post"](endpoint, "alpha", "hold", "alpha-1")
        case.assertEqual(code, 201)
        wait(lambda: len(server.calls) == 1, process, "reserved alpha reaches upstream")
        code, denied = multi["post"](endpoint, "beta", "denied", "beta-1")
        case.assertEqual(code, 201)
        denied = terminal(process, endpoint, "beta", denied["id"])
        case.assertEqual(denied["status"], "failed")
        case.assertIn("预算", denied["failure"])
        case.assertEqual(len(server.calls), 1)
        case.assertEqual(case.exchange(endpoint, "POST", f"/v1/apps/alpha/runs/{alpha['id']}/stop", {})[0], 202)
        alpha = terminal(process, endpoint, "alpha", alpha["id"])
        case.assertEqual(alpha["budget"]["status"], "pending")
        case.assertEqual(alpha["budget"]["held"], "0.146")
        case.assertIsNone(alpha["budget"]["actual"])
        case.assertEqual(alpha["stopEvidence"], "confirmedExited")
    ledger_file = root / "manager/gateway-budget-v1/ledger.json"
    original = ledger_file.read_bytes()
    with fixture["desktop"](exe, workspace, env) as (process, endpoint):
        case.assertEqual(multi["post"](endpoint, "alpha", "hold", "alpha-1"), (200, alpha))
        code, denied2 = multi["post"](endpoint, "beta", "denied-after-restart", "beta-1")
        case.assertEqual(code, 201)
        denied2 = terminal(process, endpoint, "beta", denied2["id"])
        case.assertEqual(denied2["status"], "failed")
        case.assertEqual(len(server.calls), 1)
        case.assertEqual(original, ledger_file.read_bytes())
        # An explicit edit to this disposable fixture raises its daily cap.
        policy["daily_limit"] = "0.4"; put(budget_file, policy)
        code, beta = multi["post"](endpoint, "beta", "paid", "beta-1")
        case.assertEqual(code, 201)
        beta = terminal(process, endpoint, "beta", beta["id"])
        case.assertEqual(beta["status"], "completed")
        case.assertEqual(beta["budget"]["status"], "settled")
        case.assertEqual(beta["budget"]["actual"], "0.017")
        case.assertEqual(beta["budget"]["held"], "0")
        summary = case.exchange(endpoint, "GET", "/v1/apps/beta/runtime", None)[1]["budget"]
        case.assertEqual((summary["held"], summary["spent"]), ("0.146", "0.017"))
        code, bad = multi["post"](endpoint, "beta", "bad-tail", "bad-tail")
        case.assertEqual(code, 201)
        bad = terminal(process, endpoint, "beta", bad["id"])
        case.assertEqual(bad["status"], "failed")
        case.assertEqual(bad["budget"]["status"], "pending")
        case.assertEqual(bad["budget"]["held"], "0.146")
        case.assertIsNone(bad["budget"]["actual"])
        # A missing quote denies before submission, never as zero-price fallback.
        saved = budget_file.read_bytes(); policy["prices"] = {}; put(budget_file, policy)
        try:
            code, no_price = multi["post"](endpoint, "beta", "no-price", "beta-1")
            case.assertEqual(code, 201)
            case.assertEqual(terminal(process, endpoint, "beta", no_price["id"])["status"], "failed")
        finally: budget_file.write_bytes(saved)
        case.assertEqual(len(server.calls), 3)
        # An enabled ledger cannot be disabled by deleting its policy or the gateway policy.
        budget_file.unlink()
        case.assertEqual(multi["post"](endpoint, "beta", "removed-policy", "beta-1")[0], 422)
        budget_file.write_bytes(saved)
        gateway_file = root / "manager/gateway.yaml"; saved_gateway = gateway_file.read_bytes(); gateway_file.unlink()
        case.assertEqual(multi["post"](endpoint, "beta", "removed-gateway", "beta-1")[0], 422)
        gateway_file.write_bytes(saved_gateway)
        case.assertEqual(len(server.calls), 3)
    frozen = ledger_file.read_bytes()
    with fixture["desktop"](exe, workspace, env) as (_, endpoint):
        case.assertEqual(multi["post"](endpoint, "beta", "paid", "beta-1"), (200, beta))
    case.assertEqual(frozen, ledger_file.read_bytes())
    ledger = json.loads(frozen)
    case.assertEqual(len(ledger["entries"]), 3)
    case.assertEqual(len(server.calls), 3)
    case.assertEqual(sum(Decimal(e["held"]) for e in ledger["entries"].values()), Decimal(292000000000))

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pi_bundle", type=Path)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), gateway["Model"])
    server.calls = []; server.disconnected = threading.Event(); server.disconnections = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="agentxd-pi-e2e-budget-", dir="/private/tmp") as directory:
            verify(Path(directory), args.pi_bundle, server)
        print("PASS: shared budget, pre-submit denial, pending cancellation, settlement and restart integrity")
    finally: server.shutdown(); server.server_close()
