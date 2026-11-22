"""Concurrent stop requests through the real CLI and HTTP handler."""
import json
import secrets
import subprocess
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer
from pathlib import Path

import test_agentxd_runs as fixtures
from agentxd import Handler, write_json


class TestConcurrentStop(unittest.TestCase):
    def test_independent_clients_share_pending_receipt(self):
        fixture = fixtures.TestPilotCommands()
        self.addCleanup(fixture.doCleanups)
        fixture.setUp()
        service = fixture.service
        original_factory = service.factory

        def controlled_factory(*args):
            child = original_factory(*args)
            child.finish.wait = lambda timeout=None: threading.Event.wait(child.finish)
            return child

        service.factory = controlled_factory
        _, run = service.create("create", fixture.body)
        child = fixture.children[0]
        self.addCleanup(child.finish.set)
        self.assertTrue(child.launched.wait(2))
        barrier = threading.Barrier(2)

        class ConcurrentHandler(Handler):
            def do_POST(self):
                barrier.wait(timeout=2)
                super().do_POST()

        root = Path(fixture.temp.name).resolve()
        token = secrets.token_urlsafe(32)
        with ThreadingHTTPServer(("127.0.0.1", 0), ConcurrentHandler) as server:
            server.pilots = {fixture.store.app: service}
            server.authorization = ("Bearer " + token).encode()
            write_json(root / ".agentxd-endpoint.json", {"port": server.server_port, "token": token})
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                executable = Path(__file__).resolve().parents[2] / "Scripts/agentx"

                def stop(key):
                    return json.loads(subprocess.check_output([
                        str(executable), "--root", str(root), "run", "stop", "--app", "pilot",
                        "--run", run["id"], "--idempotency-key", key], timeout=5))

                with ThreadPoolExecutor(2) as clients:
                    first, second = clients.map(stop, ("client-a", "client-b"))
            finally:
                server.shutdown()
                thread.join()
        self.assertEqual(first, second)
        self.assertEqual((first["id"], first["status"], first["stopEvidence"]),
                         (run["id"], "cancelling", "pending"))
        self.assertEqual(child.stops, 1)
        child.finish.set()
        service.close()
        final = fixture.store.get(run["id"])
        self.assertEqual((final["revision"], final["status"], final["stopEvidence"]),
                         (first["revision"] + 1, "cancelled", "confirmedExited"))
