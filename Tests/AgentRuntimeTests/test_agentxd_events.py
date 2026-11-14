"""Verify durable replay, authenticated subscriptions, and bounded cursors."""
import json
from pathlib import Path
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer

from test_agentxd_runs import RunStore
from agentxd import Handler
from websockets.sync.client import connect


class TestRunEvents(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        app = self.root / "apps/pilot"
        (app / "runs").mkdir(parents=True)
        (app / "app.yaml").touch()
        (self.root / ".agentxd-pilot.json").write_text(json.dumps({"root": str(self.root), "appID": "pilot"}))
        self.store = RunStore(self.root)
        self.store.insert(dict(id="one", appID="pilot", revision=1, status="running"))
        self.store.update("one", 1, {"stopEvidence": "pending"})

    def subscription(self, after):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.store = self.store
        server.authorization = b"Bearer test"
        server.pilot = type("Lifecycle", (), {"closing": False})()
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(server.shutdown)
        return connect(f"ws://127.0.0.1:{server.server_port}/v1/apps/pilot/runs/one/events?after={after}",
                       additional_headers={"Authorization": "Bearer test"}, proxy=None, close_timeout=1)

    def test_reconnect_reads_only_missing_revisions_after_store_reopen(self):
        with self.subscription(0) as client:
            initial = [json.loads(client.recv(2)) for _ in range(2)]
            self.assertTrue(client.ping().wait(2))
        self.assertEqual([row["revision"] for row in initial], [1, 2])
        self.store.update("one", 2, {"status": "cancelling"})
        self.store.update("one", 3, {"status": "cancelled", "stopEvidence": "confirmedExited"})
        self.store = RunStore(self.root)
        with self.subscription(2) as client:
            replay = [json.loads(client.recv(2)) for _ in range(2)]
        self.assertEqual([row["eventId"] for row in replay], ["one:3", "one:4"])
        self.assertEqual(replay, self.store.events_after("one", 2)[1]["events"])
        self.assertEqual(replay[-1]["stopEvidence"], "confirmedExited")
        self.assertEqual(self.store.events_after("one", 4)[1]["events"], [])

    def test_expired_and_future_cursor_require_snapshot_and_noop_preserves_file(self):
        for revision in range(2, 70):
            self.store.update("one", revision, {"isRead": revision % 2 == 0})
        self.assertEqual(self.store.events_after("one", 2)[0], 409)
        self.assertEqual(self.store.events_after("one", 71)[0], 409)
        self.assertEqual(len(self.store.events_after("one", 6)[1]["events"]), 64)
        file = self.store.directory / "one.json"
        before = (file.read_bytes(), file.stat().st_mtime_ns)
        self.store.update("one", 70, {"isRead": False})
        self.assertEqual((file.read_bytes(), file.stat().st_mtime_ns), before)
