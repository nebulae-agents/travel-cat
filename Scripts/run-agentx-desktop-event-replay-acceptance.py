#!/usr/bin/env python3
"""Compare HTTP replay and live WebSocket subscriptions on isolated Python and desktop writers."""
import argparse
import base64
import http.client
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import runpy
import socket
import tempfile
import threading
import time

from websockets.sync.client import connect

controls = runpy.run_path(str(Path(__file__).with_name("run-agentx-desktop-run-controls-acceptance.py")))
multi, fixture, case = (controls[key] for key in ("multi", "fixture", "case"))


def subscribe(endpoint, path, cursor):
    headers = {"Authorization": "Bearer " + endpoint["token"]}
    return connect(f"ws://127.0.0.1:{endpoint['port']}{path}/events?after={cursor}",
                   additional_headers=headers, proxy=None, open_timeout=4, close_timeout=1)


def rejected_upgrade(endpoint, path, cursor, authorized=True):
    # The reference handler returns pre-upgrade errors using HTTP/1.0.
    conn = http.client.HTTPConnection("127.0.0.1", endpoint["port"], timeout=4)
    headers = {"Upgrade": "websocket", "Connection": "Upgrade", "Sec-WebSocket-Version": "13",
               "Sec-WebSocket-Key": base64.b64encode(os.urandom(16)).decode()}
    if authorized:
        headers["Authorization"] = "Bearer " + endpoint["token"]
    try:
        conn.request("GET", f"{path}/events?after={cursor}", headers=headers)
        response = conn.getresponse()
        return response.status, json.load(response)
    finally:
        conn.close()


def verify_subscription(endpoint, path):
    def change(revision):
        code, result = case.exchange(endpoint, "PATCH", path, {
            "expectedRevision": revision, "isRead": revision % 2 == 0})
        case.assertEqual((code, result["revision"]), (200, revision + 1))

    for url, cursor, authorized, status in [(path, 0, False, 401), (path, 1, True, 409),
            (path, "bad", True, 400), (path.replace("/alpha/", "/beta/"), 0, True, 404)]:
        case.assertEqual(rejected_upgrade(endpoint, url, cursor, authorized)[0], status)

    with subscribe(endpoint, path, 0) as first:
        # Ordinary HTTP connections time out after 5s. Idle subscriptions must survive.
        time.sleep(5.2)
        case.assertTrue(first.ping().wait(2))
        change(0)
        change(1)
        seen = [json.loads(first.recv(3)) for _ in range(2)]
        change(2)  # Persisted, but the client has not consumed this frame.
        first.socket.shutdown(socket.SHUT_RDWR)
    change(3)
    change(4)
    with subscribe(endpoint, path, seen[-1]["revision"]) as resumed:
        change(5)  # A live update may overlap sending the replay.
        seen.extend(json.loads(resumed.recv(3)) for _ in range(4))
        with case.assertRaises(TimeoutError):
            resumed.recv(.4)
    expected = [dict(eventId=f"stream:{n}", runId="stream", revision=n, kind="readFlagChanged",
                     state="completed") for n in range(1, 7)]
    case.assertEqual(seen, expected)
    code, durable = case.exchange(endpoint, "GET", path + "/events?after=0", None)
    case.assertEqual((code, durable["events"]), (200, seen))
    return seen


def verify(engine, workspace, bundle, server):
    root = multi["configure"](workspace, server.server_port)
    file = root / "apps/alpha/runs/old.json"
    put = multi["pilot"]["put"]
    put(file, controls["legacy"])
    put(file.with_name("stream.json"), dict(controls["legacy"], id="stream"))
    stream_path = "/v1/apps/alpha/runs/stream"
    original = file.read_bytes()
    # Older desktop versions sometimes saved a terminal revision without an event.
    stale = dict(controls["legacy"], id="gap", revision=3, events=[
        dict(eventId="gap:2", runId="gap", revision=2, kind="readFlagChanged", state="completed")])
    put(file.with_name("gap.json"), stale)
    if engine == "python":
        marker = root / ".agentxd-pilot.json"
        config = json.loads(marker.read_bytes())
        del config["writer"]
        put(marker, config)
        helper = controls["reference"].audit_helper(workspace / "audit-helper")

        def launch():
            return controls["python_service"](workspace, bundle, helper)
    else:
        exe, env = fixture["prepare_desktop"](workspace, bundle)

        def launch():
            return fixture["desktop"](exe, workspace, env)

    path = "/v1/apps/alpha/runs/old"
    with launch() as (process, endpoint):
        def get(url, authorized=True):
            return case.exchange(endpoint, "GET", url, None, authorize=authorized)

        def replay(cursor):
            return get(f"{path}/events?after={cursor}")

        case.assertEqual(replay(0), (200, {"revision": 0, "events": []}))
        case.assertEqual(get(path + "/events?after=0", False), (401, {}))
        for absent in [path.replace("/alpha/", "/beta/"), path + "-absent"]:
            case.assertEqual(get(absent + "/events?after=0"), (404, {}))
        for query in ["", "?after=", "?after=-1", "?after=1.0", "?after=0&after=1", "?after=" + "0"*20]:
            case.assertEqual(get(path + "/events" + query), (400, {"error": "invalid_cursor"}))
        case.assertEqual(file.read_bytes(), original)
        gap = path.removesuffix("old") + "gap"
        case.assertEqual(get(gap + "/events?after=1"), (409, {"error": "snapshot_required", "revision": 3}))
        case.assertEqual(rejected_upgrade(endpoint, gap, 1), (409, {"error": "snapshot_required", "revision": 3}))
        case.assertEqual(get(gap + "/events?after=3"), (200, {"revision": 3, "events": []}))
        for revision in range(66):
            code, changed = case.exchange(endpoint, "PATCH", path, {
                "expectedRevision": revision, "isRead": revision % 2 == 0})
            case.assertEqual((code, changed["revision"]), (200, revision + 1))
        expected = [dict(eventId=f"old:{n}", runId="old", revision=n, kind="readFlagChanged",
                         state="completed") for n in range(3, 67)]
        for cursor in [2, 32, 65, 66, "0000000000000000002"]:
            case.assertEqual(replay(cursor), (200, {"revision": 66, "events": [
                event for event in expected if event["revision"] > int(cursor)]}))
        for cursor in [0, 1, 67, "9999999999999999999"]:
            case.assertEqual(replay(cursor), (409, {"error": "snapshot_required", "revision": 66}))
        code, live = multi["post"](endpoint, "alpha", "replay", "alpha-1")
        case.assertEqual(code, 201)
        live_path = path.removesuffix("old") + live["id"]
        fixture["wait_for"](lambda: len(server.calls) == 1, process, "Pi reached the isolated model")
        code, running = get(live_path)
        case.assertEqual((code, running["status"]), (200, "running"))
        with subscribe(endpoint, live_path, running["revision"]) as live_socket:
            server.release.set()
            terminal = json.loads(live_socket.recv(5))
            case.assertEqual((terminal["runId"], terminal["state"], terminal["revision"]),
                             (live["id"], "completed", running["revision"] + 1))

        def completed():
            code, result = get(live_path)
            return result if code == 200 and result["status"] == "completed" else None
        final = fixture["wait_for"](completed, process, "run completed")
        code, batch = get(live_path + "/events?after=0")
        case.assertEqual((code, batch["revision"]), (200, final["revision"]))
        events = batch["events"]
        case.assertIn(terminal, events)
        case.assertEqual([e["eventId"] for e in events], [
            f"{live['id']}:{n}" for n in range(1, final["revision"] + 1)])
        case.assertEqual((events[0]["kind"], events[0]["state"], events[-1]["state"]),
                         ("created", "running", "completed"))
        with subscribe(endpoint, path, 2) as retained:
            case.assertEqual([json.loads(retained.recv(3)) for _ in expected], expected)
        seen = verify_subscription(endpoint, stream_path)
        case.assertEqual(rejected_upgrade(endpoint, path, 1),
                         (409, {"error": "snapshot_required", "revision": 66}))
        frozen = {p: p.read_bytes() for p in file.parent.glob("*.json")}
    with launch() as (_, endpoint):
        with subscribe(endpoint, stream_path, 4) as resumed:
            case.assertEqual([json.loads(resumed.recv(3)) for _ in range(2)], seen[4:])
            with case.assertRaises(TimeoutError):
                resumed.recv(.4)
        case.assertEqual(replay(65), (200, {"revision": 66, "events": expected[-1:]}))
        case.assertEqual(get(live_path + "/events?after=0"), (200, batch))
    case.assertEqual(frozen, {p: p.read_bytes() for p in file.parent.glob("*.json")})
    case.assertEqual(len(server.calls), 1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pi_bundle", type=Path)
    args = parser.parse_args()
    for engine in ("python", "desktop"):
        with tempfile.TemporaryDirectory(prefix="agentxd-pi-e2e-", dir="/private/tmp") as directory:
            with ThreadingHTTPServer(("127.0.0.1", 0), multi["Model"]) as server:
                server.calls, server.release, server.lock = [], threading.Event(), threading.Lock()
                threading.Thread(target=server.serve_forever, daemon=True).start()
                try:
                    verify(engine, Path(directory), args.pi_bundle, server)
                finally:
                    server.release.set()
                    server.shutdown()
        print("PASS:", engine, "HTTP replay, WebSocket live delivery, disconnect/resume and restart", flush=True)
