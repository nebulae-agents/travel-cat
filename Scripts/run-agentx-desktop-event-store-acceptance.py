#!/usr/bin/env python3
"""Exercise the opt-in desktop event store with real Pi, loopback SSE and a disposable root."""
import argparse
from collections import Counter
from contextlib import ExitStack
import getpass
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
import threading

contract = runpy.run_path(str(Path(__file__).with_name("run-agentx-desktop-contract-acceptance.py")))
multi, fixture, case, replay = (contract[k] for k in ("multi", "fixture", "case", "replay"))
KEY = "same-key"
FIRST = "猫🐾 "
LAST = "arrived."


class Model(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        prompt = body["messages"][-1]["content"]
        if isinstance(prompt, list):
            prompt = "".join(part.get("text", "") for part in prompt)
        if self.path != "/v1/chat/completions" or prompt not in ("alpha-1", "beta-1"):
            return self.send_error(400)
        self.server.calls.append(prompt)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def chunk(choices, **other):
            data = dict(id="fixture", choices=choices, **other)
            self.wfile.write(("data: " + json.dumps(data) + "\n\n").encode())
            self.wfile.flush()

        try:
            if prompt == "alpha-1":
                if not self.server.start.wait(30):
                    return
                chunk([dict(index=0, delta={"content": FIRST}, finish_reason=None)])
                if not self.server.finish.wait(30):
                    return
            chunk([dict(index=0, delta={"content": LAST}, finish_reason=None)])
            chunk([dict(index=0, delta={}, finish_reason="stop")])
            if prompt == "alpha-1":
                chunk([], usage=dict(prompt_tokens=11, completion_tokens=3, total_tokens=14))
            self.wfile.write(b"data: [DONE]\n\n")
        except (BrokenPipeError, ConnectionResetError):
            pass


def get(endpoint, path):
    code, result = case.exchange(endpoint, "GET", path, None)
    case.assertEqual(code, 200, path)
    return result


def audit_hashes(root, app):
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (root / "audit" / app).glob("*.event")}


def path(app, run_id):
    return f"/v1/apps/{app}/runs/{run_id}"


def verify(workspace, bundle, server):
    root = multi["configure"](workspace, server.server_port)
    put = multi["pilot"]["put"]
    marker = root / ".agentxd-pilot.json"
    config = json.loads(marker.read_bytes())
    legacy = {}
    for entry in config["apps"]:
        app = entry["appID"]
        entry["runStore"] = "events-v1"
        legacy[app] = dict(replay["controls"]["legacy"], appID=app, instanceID="pi-" + app,
                           extension={"owner": app, "nested": [None, False, 42]})
        put(root / "apps" / app / "runs/old.json", legacy[app])
    put(marker, config)
    exe, env = fixture["prepare_desktop"](workspace, bundle)

    def launch():
        return fixture["desktop"](exe, workspace, env)

    alpha_old = path("alpha", "old")
    beta_old = path("beta", "old")
    with ExitStack() as outage, launch() as (process, endpoint):
        for app, row in legacy.items():
            case.assertEqual(get(endpoint, path(app, "old")), dict(row, revision=0))
            case.assertEqual(get(endpoint, path(app, "old") + "/events?after=0"), dict(revision=0, events=[]))
        # The cache remains stale while its directory is read-only. The next
        # successful checkpoint or restart must reproduce the committed update.
        folder = root / "apps/alpha/runs"
        old_cache = (folder / "old.json").read_bytes()
        mode = folder.stat().st_mode & 0o777
        folder.chmod(0o500)
        try:
            code, changed = case.exchange(endpoint, "PATCH", alpha_old, dict(expectedRevision=0, isRead=True))
            case.assertEqual((code, changed["revision"], get(endpoint, alpha_old)), (200, 1, changed))
            case.assertEqual((folder / "old.json").read_bytes(), old_cache)
        finally:
            folder.chmod(mode)
        for n in range(1, 66):
            code, changed = case.exchange(endpoint, "PATCH", alpha_old, dict(expectedRevision=n, isRead=n % 2 == 0))
            case.assertEqual((code, changed["revision"], changed["extension"]), (200, n+1, legacy["alpha"]["extension"]))
        tail = get(endpoint, alpha_old + "/events?after=2")
        case.assertEqual([e["revision"] for e in tail["events"]], list(range(3, 67)))
        case.assertTrue(all(e["kind"] == "readFlagChanged" for e in tail["events"]))
        stale = (409, {"error": "snapshot_required", "revision": 66})
        case.assertEqual(case.exchange(endpoint, "GET", alpha_old + "/events?after=1", None), stale)
        case.assertEqual(replay["rejected_upgrade"](endpoint, alpha_old, 1), stale)

        code, beta = multi["post"](endpoint, "beta", KEY, "beta-1")
        case.assertEqual(code, 201)
        beta_path = path("beta", beta["id"])

        def terminal(url, audit):
            row = get(endpoint, url)
            return row if (row["status"], row.get("auditStatus")) == ("completed", audit) else None

        beta = fixture["wait_for"](lambda: terminal(beta_path, "confirmed"), process, "beta completion")
        beta_events = get(endpoint, beta_path + "/events?after=0")
        case.assertEqual(beta["response"], LAST)
        case.assertNotIn("usage", beta)
        case.assertFalse(any(e["kind"] == "usageReported" for e in beta_events["events"]))
        beta_chain = audit_hashes(root, "beta")
        case.assertEqual(len(beta_chain), 2)
        code, created = multi["post"](endpoint, "alpha", KEY, "alpha-1")
        case.assertEqual(code, 201)
        live_path = path("alpha", created["id"])
        with replay["subscribe"](endpoint, live_path, created["revision"]) as stream:
            server.start.set()
            # Withhold the rest of the SSE body until the live subscriber sees the first delta.
            first = json.loads(stream.recv(10))
            case.assertEqual((first["kind"], first["text"], first["state"]), ("textDelta", FIRST, "running"))
            cache_file = root / "apps/alpha/runs" / (created["id"] + ".json")
            checkpoint = json.loads(cache_file.read_bytes())
            case.assertLess(checkpoint["revision"], first["revision"])
            case.assertEqual(get(endpoint, live_path)["response"], FIRST)
            outage.enter_context(contract["unavailable_audit"](root))
            server.finish.set()
        pending = fixture["wait_for"](lambda: terminal(live_path, "pending"), process, "pending terminal projection")
        case.assertEqual(pending["response"], FIRST + LAST)
        case.assertEqual(pending["usage"], {"inputTokens": 11, "outputTokens": 3})
        batch = get(endpoint, live_path + "/events?after=0")
        events = batch["events"]
        case.assertIn(first, events)
        case.assertEqual([e["revision"] for e in events], list(range(1, pending["revision"] + 1)))
        case.assertEqual("".join(e["text"] for e in events if e["kind"] == "textDelta"), FIRST + LAST)
        usage = [e for e in events if e["kind"] == "usageReported"]
        case.assertEqual([(e["inputTokens"], e["outputTokens"]) for e in usage], [(11, 3)])
        case.assertEqual(get(endpoint, beta_old), dict(legacy["beta"], revision=0))

    start_chain = audit_hashes(root, "alpha")
    case.assertEqual(len(start_chain), 1)
    # Move both apps' isolated projections, including alpha's pending audit intent.
    for app in legacy:
        directory = root / "apps" / app / "runs"
        directory.rename(workspace / ("projections-" + app))

    with launch() as (_, endpoint):
        case.assertEqual(get(endpoint, alpha_old), changed)
        case.assertEqual(get(endpoint, alpha_old + "/events?after=2"), tail)
        case.assertEqual(case.exchange(endpoint, "GET", alpha_old + "/events?after=1", None), stale)
        with replay["subscribe"](endpoint, alpha_old, 64) as resumed:
            case.assertEqual([json.loads(resumed.recv(3)) for _ in range(2)], tail["events"][-2:])
        case.assertEqual(get(endpoint, beta_old), dict(legacy["beta"], revision=0))
        case.assertEqual(get(endpoint, beta_path), beta)
        case.assertEqual(get(endpoint, beta_path + "/events?after=0"), beta_events)
        recovered = get(endpoint, live_path)
        case.assertEqual((recovered["status"], recovered["response"], recovered["auditStatus"]),
                         ("completed", FIRST + LAST, "confirmed"))
        after = get(endpoint, live_path + "/events?after=0")["events"]
        case.assertEqual(after[:-1], events)
        case.assertEqual(after[-1]["kind"], "auditConfirmed")
        for app, row in (("alpha", recovered), ("beta", beta)):
            case.assertEqual(multi["post"](endpoint, app, KEY, app + "-1"), (200, row))
            report = get(endpoint, path(app, row["id"]) + "/audit")
            case.assertIs(report["verified"], True)
            case.assertEqual([r["kind"] for r in report["records"]], ["model.request.started", "model.request.completed"])
            for rid, expected in ((row["id"], row), ("old", changed if app == "alpha" else dict(legacy[app], revision=0))):
                projection = root / "apps" / app / "runs" / (rid + ".json")
                case.assertEqual(json.loads(projection.read_bytes()), expected)

    chain = audit_hashes(root, "alpha")
    case.assertEqual(len(chain), 2)
    case.assertTrue(start_chain.items() <= chain.items())
    case.assertEqual(audit_hashes(root, "beta"), beta_chain)
    with launch() as (_, endpoint):
        case.assertEqual(multi["post"](endpoint, "alpha", KEY, "alpha-1"), (200, recovered))
        case.assertEqual(get(endpoint, live_path + "/events?after=0")["events"], after)
    case.assertEqual(audit_hashes(root, "alpha"), chain)
    case.assertEqual(audit_hashes(root, "beta"), beta_chain)
    # An intact journal can still serve history when the missing cache directory
    # cannot be recreated at startup.
    app_dir = root / "apps/beta"
    (app_dir / "runs").rename(workspace / "beta-before-readonly-start")
    # Allow the manager's normal app.yaml save while denying only mkdir.
    acl = f"user:{getpass.getuser()} deny add_subdirectory"
    subprocess.run(["/bin/chmod", "+a", acl, app_dir], check=True)
    try:
        with launch() as (_, endpoint):
            case.assertEqual(get(endpoint, beta_path), beta)
            case.assertFalse((app_dir / "runs").exists())
    finally:
        subprocess.run(["/bin/chmod", "-a", acl, app_dir], check=True)
    journal = root / "apps/alpha/events/run-journal"
    case.assertGreaterEqual(len(list(journal.glob("segment-*.jsonl"))), 2)
    # Losing the authority must not turn a stale projection into a new authority,
    # including when someone also removes the opt-in from the retired marker.
    moved = workspace / "kept-alpha-journal"
    journal.rename(moved)
    for remove_opt_in in (False, True):
        if remove_opt_in:
            del config["apps"][0]["runStore"]
            put(marker, config)
        with launch() as (_, endpoint):
            case.assertEqual(case.exchange(endpoint, "GET", live_path, None)[0], 503)
            case.assertEqual(get(endpoint, beta_path), beta)
            case.assertFalse(journal.exists())
    journal_revisions = [json.loads(row)["sequence"] for segment in sorted(moved.glob("segment-*.jsonl"))
                         for row in segment.read_bytes().splitlines()]
    case.assertEqual(journal_revisions, list(range(1, len(journal_revisions) + 1)))
    case.assertEqual(Counter(server.calls), {"alpha-1": 1, "beta-1": 1})


def verify_stream_stop(workspace, bundle, server):
    root = multi["configure"](workspace, server.server_port)
    marker = root / ".agentxd-pilot.json"
    config = json.loads(marker.read_bytes())
    for entry in config["apps"]:
        entry["runStore"] = "events-v1"
    multi["pilot"]["put"](marker, config)
    exe, env = fixture["prepare_desktop"](workspace, bundle)
    with fixture["desktop"](exe, workspace, env) as (process, endpoint):
        code, run = multi["post"](endpoint, "alpha", KEY, "alpha-1")
        case.assertEqual((code, run["runtimeCore"]), (201, "pi-agent-core"))
        url = path("alpha", run["id"])
        with replay["subscribe"](endpoint, url, run["revision"]) as stream:
            server.start.set()
            event = json.loads(stream.recv(10))
            case.assertEqual((event["kind"], event["text"]), ("textDelta", FIRST))
            code, pending = case.exchange(endpoint, "POST", url + "/stop", {})
            case.assertEqual((code, pending["status"]), (202, "cancelling"))

        def cancelled():
            row = get(endpoint, url)
            return row if row["status"] == "cancelled" and row.get("auditStatus") == "confirmed" else None

        final = fixture["wait_for"](cancelled, process, "cancelled stream with verified audit")
        case.assertEqual((final["response"], final["stopEvidence"]), (FIRST, "confirmedExited"))
        case.assertNotIn("usage", final)
        server.finish.set()

    with fixture["desktop"](exe, workspace, env) as (_, endpoint):
        case.assertEqual(get(endpoint, url), final)
        case.assertEqual(multi["post"](endpoint, "alpha", KEY, "alpha-1"), (200, final))
        events = get(endpoint, url + "/events?after=0")["events"]
        case.assertEqual([e["text"] for e in events if e["kind"] == "textDelta"], [FIRST])
        case.assertEqual(server.calls, ["alpha-1"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pi_bundle", type=Path)
    parser.add_argument("--stop-during-stream", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="agentxd-pi-e2e-", dir="/private/tmp") as directory:
        with ThreadingHTTPServer(("127.0.0.1", 0), Model) as server:
            server.start, server.finish, server.calls = threading.Event(), threading.Event(), []
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                scenario = verify_stream_stop if args.stop_during_stream else verify
                scenario(Path(directory), args.pi_bundle, server)
            finally:
                server.start.set()
                server.finish.set()
                server.shutdown()
                thread.join(timeout=3)
    print("PASS: stop during live Pi output, exit receipt, partial history and idempotent restart."
          if args.stop_during_stream else
          "PASS: desktop event store, live Pi deltas and usage, bounded replay, projection rebuild and audit recovery.")
