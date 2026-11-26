#!/usr/bin/env python3
"""Check desktop runtime selection and offline diagnostics in a temporary two-app root."""
import argparse
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
import threading

suite = runpy.run_path(str(Path(__file__).with_name("run-agentx-desktop-event-store-acceptance.py")))
case, fixture, multi = (suite[name] for name in ("case", "fixture", "multi"))
get = suite["get"]


def verify(workspace, bundle, model):
    root = multi["configure"](workspace, model.server_port)
    put = multi["pilot"]["put"]
    marker = root / ".agentxd-pilot.json"
    config = json.loads(marker.read_bytes())
    config["apps"][0]["runStore"] = "events-v1"
    put(marker, config)

    def select(app, runtime):
        put(root / "apps" / app / "app.yaml", dict(id=app, name=app, kind="chat", enabled=True, runtime=runtime))

    select("alpha", "pi-agent-core")
    exe, env = fixture["prepare_desktop"](workspace, bundle)
    url = "/v1/apps/alpha/runtime"
    with fixture["desktop"](exe, workspace, env) as (proc, endpoint):
        report = get(endpoint, url)
        case.assertEqual(report, dict(appID="alpha", configuredRuntime="pi-agent-core", runtimeCore="pi-agent-core",
                                      health="ready", capabilities=dict(start=True, stop=True, stream=True,
                                                                        usage=True, tools=False, step=False)))
        cli = Path(__file__).with_name("agentx")
        case.assertEqual(json.loads(subprocess.check_output([cli, "--root", root, "runtime", "status", "--app", "alpha"])), report)
        beta = get(endpoint, "/v1/apps/beta/runtime")
        case.assertEqual((beta["configuredRuntime"], beta["health"], beta["capabilities"]["stream"],
                          beta["capabilities"]["usage"]), (None, "ready", False, False))
        case.assertEqual(case.exchange(endpoint, "GET", url, None, authorize=False)[0], 401)
        case.assertEqual(case.exchange(endpoint, "GET", "/v1/apps/absent/runtime", None)[0], 404)
        case.assertEqual(case.exchange(endpoint, "POST", url, None)[0], 405)
        # Hide only the runner copied into this temporary bundle.
        runner = exe.parents[1] / "Resources/PiAgent/runner.mjs"
        hidden = runner.with_suffix(".disabled")
        runner.rename(hidden)
        try:
            case.assertEqual(get(endpoint, url)["health"], "missing_runtime")
        finally:
            hidden.rename(runner)
        case.assertEqual(model.calls, [])
        model.start.set()
        model.finish.set()
        code, created = multi["post"](endpoint, "alpha", "first", "alpha-1")
        case.assertEqual(code, 201)
        run_url = suite["path"]("alpha", created["id"])

        def completed():
            row = get(endpoint, run_url)
            return row if row["status"] == "completed" and row.get("auditStatus") == "confirmed" else None

        final = fixture["wait_for"](completed, proc, "explicit Pi selection")
        case.assertEqual(final["runtimeCore"], "pi-agent-core")
        case.assertEqual(final["usage"], dict(inputTokens=11, outputTokens=3))

    select("alpha", "unknown-engine")
    select("beta", "host-text")
    with fixture["desktop"](exe, workspace, env) as (_, endpoint):
        report = get(endpoint, url)
        case.assertEqual((report["health"], report["runtimeCore"], report["capabilities"]), ("unsupported_runtime", None, {}))
        case.assertEqual(multi["post"](endpoint, "alpha", "second", "alpha-1"), (422, {"error": "unsupported_runtime"}))
        case.assertEqual(multi["post"](endpoint, "alpha", "first", "alpha-1"), (200, final))
        beta = get(endpoint, "/v1/apps/beta/runtime")
        case.assertEqual((beta["configuredRuntime"], beta["runtimeCore"], beta["health"]), ("host-text", "pi-agent-core", "ready"))
        case.assertEqual(model.calls, ["alpha-1"])

    select("alpha", "native-http")
    del config["apps"][1]["pi"]
    put(marker, config)
    with fixture["desktop"](exe, workspace, env) as (_, endpoint):
        case.assertEqual(get(endpoint, url)["health"], "unsupported_runtime")
        case.assertEqual(get(endpoint, "/v1/apps/beta/runtime")["health"], "unbound")
        case.assertEqual(multi["post"](endpoint, "alpha", "third", "alpha-1"), (422, {"error": "unsupported_runtime"}))
        case.assertEqual(model.calls, ["alpha-1"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pi_bundle", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="agentxd-pi-e2e-", dir="/private/tmp") as folder:
        with ThreadingHTTPServer(("127.0.0.1", 0), suite["Model"]) as model:
            model.start, model.finish, model.calls = threading.Event(), threading.Event(), []
            thread = threading.Thread(target=model.serve_forever, daemon=True)
            thread.start()
            try:
                verify(Path(folder), args.pi_bundle, model)
            finally:
                model.start.set()
                model.finish.set()
                model.shutdown()
                thread.join(timeout=3)
    print("PASS: runtime selection, authenticated offline diagnostics, one Pi execution and replay after reconfiguration.")
