"""Single-writer pilot for an explicitly configured, offline copy of an AgentX root."""
import argparse
import fcntl
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import signal
import stat
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import RLock

from agentxd_runs import PilotRuns, CommandError
from agentxd_audit import enqueue, SwiftAudit


IDENTIFIER = re.compile(r"[A-Za-z0-9_-]{1,100}")


def regular(path):
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError("expected a regular file")
    return path


def read_json(path):
    return json.loads(regular(path).read_bytes())


def write_json(path, value):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(json.dumps(value, ensure_ascii=False, allow_nan=False).encode())
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(temporary, path)
            directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            temporary.unlink(missing_ok=True)


class RunStore:
    def __init__(self, root, audit=None):
        self.audit = audit
        config = read_json(root / ".agentxd-pilot.json")
        self.config = config
        self.app = config["appID"]
        configured = Path(config["root"])
        if (not configured.is_absolute() or configured.resolve(strict=True) != root or not IDENTIFIER.fullmatch(self.app)
                or self.app.lower() != self.app or self.app in ("blackcat", "workbench")):
            raise ValueError("invalid pilot ownership")
        self.directory = root / "apps" / self.app / "runs"
        if self.directory.resolve(strict=True) != self.directory or not self.directory.is_dir():
            raise ValueError("invalid runs directory")
        regular(self.directory.parent / "app.yaml")
        self.lock = RLock()

    def get(self, run_id):
        if not IDENTIFIER.fullmatch(run_id):
            raise FileNotFoundError()
        run = read_json(self.directory / (run_id + ".json"))
        if run["appID"] != self.app or run["id"] != run_id:
            raise ValueError("inconsistent run identity")
        run.setdefault("revision", 0)
        if type(run["revision"]) is not int or run["revision"] < 0:
            raise ValueError("invalid revision")
        return run

    def list_runs(self):
        with self.lock:
            return [self.get(path.stem) for path in sorted(self.directory.glob("*.json"))]

    @staticmethod
    def record_event(run, kind):
        revision = run["revision"]
        event = {"eventId": f'{run["id"]}:{revision}', "runId": run["id"],
                 "revision": revision, "kind": kind, "state": run["status"]}
        if run.get("stopEvidence"):
            event["stopEvidence"] = run["stopEvidence"]
        run["events"] = (run.get("events", []) + [event])[-64:]

    def events_after(self, run_id, cursor):
        run = self.get(run_id)
        revision = run["revision"]
        events = run.get("events", [])
        oldest_cursor = events[0]["revision"] - 1 if events else revision
        if not oldest_cursor <= cursor <= revision:
            return 409, {"error": "snapshot_required", "revision": revision}
        return 200, {"revision": revision, "events": [e for e in events if e["revision"] > cursor]}

    def flush_audit(self, run):
        if run.get("auditStatus") != "pending":
            return run
        if self.audit is None:
            return run
        try:
            for record in run["auditOutbox"][run.get("auditDelivered", 0):]:
                self.audit.append(record)
            acknowledged = dict(run, auditStatus="confirmed", auditFailure=None, auditDelivered=len(run["auditOutbox"]), revision=run["revision"] + 1)
            self.record_event(acknowledged, "auditConfirmed")
            write_json(self.directory / (run["id"] + ".json"), acknowledged)
            return acknowledged
        except (OSError, ValueError):
            return run  # Keep durable outbox and result; retry on recovery/new create.

    def recover_audit(self):
        with self.lock:
            for run in self.list_runs():
                self.flush_audit(run)

    def insert(self, run):
        with self.lock:
            target = self.directory / (run["id"] + ".json")
            if target.exists():
                raise FileExistsError("run already exists")
            enqueue(run, "started")
            self.record_event(run, "created")
            write_json(target, run)
            run.update(self.flush_audit(run))

    def update(self, run_id, expected, changes, *, flush_audit=True):
        with self.lock:
            run = self.get(run_id)
            if run["revision"] != expected:
                return 409, run
            if any(run.get(key) != value for key, value in changes.items()):
                previous = run.get("status")
                run.update(changes)
                if previous != run.get("status"):
                    phase = {"cancelling": "cancel_requested", "completed": "completed",
                             "failed": "failed", "cancelled": "cancelled"}.get(run.get("status"))
                    if phase:
                        enqueue(run, phase)
                run["revision"] += 1
                kind = "readFlagChanged" if set(changes) == {"isRead"} else "updated"
                self.record_event(run, kind)
                write_json(self.directory / (run_id + ".json"), run)
                if flush_audit:
                    run = self.flush_audit(run)
            return 200, run


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # URLs contain private run identifiers.

    def setup(self):
        self.request.settimeout(3)
        super().setup()

    def reply(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def stream_events(self, run_id, cursor):
        # The HTTP parser consumed the opening request. Give its headers to
        # the WebSocket protocol implementation before switching transports.
        from select import select
        try:
            from websockets.datastructures import Headers
            from websockets.http11 import Request
            from websockets.server import ServerProtocol
            from websockets.protocol import OPEN
        except ImportError:
            return self.reply(503, {"error": "websocket_runtime_unavailable"})
        status, batch = self.server.store.events_after(run_id, cursor)
        if status != 200:
            return self.reply(status, batch)
        protocol = ServerProtocol(max_size=4096)
        opening = Request(self.path, Headers(self.headers.items()))
        protocol.receive_data(opening.serialize())
        handshake = protocol.accept(protocol.events_received()[0])
        protocol.send_response(handshake)
        self.close_connection = True
        def flush():
            for data in protocol.data_to_send():
                if data:
                    self.connection.sendall(data)
        flush()
        while protocol.state is OPEN and not self.server.pilot.closing:
            if status != 200:
                protocol.send_text(json.dumps(batch).encode())
                protocol.send_close(1000)
            else:
                for event in batch["events"]:
                    protocol.send_text(json.dumps(event).encode())
                cursor = batch["revision"]
            flush()
            if protocol.state is not OPEN:
                break
            if select([self.connection], [], [], .25)[0]:
                data = self.connection.recv(4096)
                if not data:
                    break
                protocol.receive_data(data)
                protocol.events_received()
                flush()
            status, batch = self.server.store.events_after(run_id, cursor)

    def handle_run(self):
        server = self.server
        if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), server.authorization):
            return self.reply(401, {})
        parts = self.path.split("/")
        if parts[:5] != ["", "v1", "apps", server.store.app, "runs"]:
            return self.reply(404, {})
        route = parts[5:]
        try:
            if self.command == "GET":
                if len(route) == 2 and route[1] == "audit":
                    with server.store.lock:
                        run = server.store.get(route[0])
                        if server.store.audit is None:
                            raise CommandError(503, "audit_unavailable")
                        try:
                            count = server.store.audit.verify()
                            records = server.store.audit.records(route[0])
                        except (OSError, ValueError):
                            raise CommandError(503, "audit_unavailable") from None
                        return self.reply(200, {"runId": run["id"], "appID": server.store.app,
                                                "auditStatus": run.get("auditStatus", "legacy"),
                                                "verified": True, "chainRecords": count, "records": records})
                if len(route) == 2 and route[1].partition("?")[0] == "events":
                    query = re.fullmatch(r"events\?after=([0-9]{1,19})", route[1])
                    if not query:
                        return self.reply(400, {"error": "invalid_cursor"})
                    cursor = int(query[1])
                    if self.headers.get("Upgrade", "").lower() == "websocket":
                        return self.stream_events(route[0], cursor)
                    return self.reply(*server.store.events_after(route[0], cursor))
                if len(route) > 1:
                    return self.reply(404, {})
                result = server.store.get(route[0]) if route else server.store.list_runs()
                return self.reply(200, result)
            if self.headers.get("Transfer-Encoding") is not None:
                return self.reply(400, {})
            length = self.headers.get("Content-Length", "0")
            maximum = 640000 if self.command == "POST" and not route else 1024
            if not re.fullmatch(r"[0-9]{1,8}", length) or int(length) > maximum:
                return self.reply(400, {})
            try:
                body = json.loads(self.rfile.read(int(length))) if int(length) else {}
            except (ValueError, UnicodeError):
                return self.reply(400, {})
            if self.command == "POST":
                key = self.headers.get("Idempotency-Key")
                if not route:
                    return self.reply(*server.pilot.create(key, body))
                if len(route) == 2 and route[1] == "stop" and body == {}:
                    return self.reply(*server.pilot.stop(route[0], key))
                return self.reply(404, {})
            if len(route) != 1:
                return self.reply(405, {})
            if (not isinstance(body, dict) or set(body) != {"expectedRevision", "isRead"}
                    or type(body["isRead"]) is not bool or type(body["expectedRevision"]) is not int
                    or body["expectedRevision"] < 0):
                return self.reply(400, {})
            self.reply(*server.store.update(route[0], body["expectedRevision"], {"isRead": body["isRead"]}))
        except CommandError as error:
            self.reply(error.status, {"error": error.reason})
        except FileNotFoundError:
            self.reply(404, {})
        except (ValueError, TypeError, OSError, KeyError):
            self.reply(500, {})

    do_GET = do_PATCH = do_POST = handle_run


def serve(root, on_ready=None, *, pi_bundle=None, audit_helper=None):
    root = root.resolve(strict=True)
    info = root.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("pilot root must be private (0700)")
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("pilot root already in use") from None
        if any((root / name).exists() for name in (".agentx-local-operation.json", ".agentx-transaction.json")):
            raise ValueError("finish the pending desktop transaction before starting the pilot")
        store = RunStore(root)
        if audit_helper is None and pi_bundle is not None:
            import plistlib
            with regular(pi_bundle / "Contents/Info.plist").open("rb") as stream:
                executable = plistlib.load(stream)["CFBundleExecutable"]
            if not isinstance(executable, str) or not IDENTIFIER.fullmatch(executable):
                raise ValueError("invalid bundle executable")
            audit_helper = pi_bundle / "Contents/MacOS" / executable
        if audit_helper is not None:
            store.audit = SwiftAudit(root, store.app, audit_helper)
        endpoint = root / ".agentxd-endpoint.json"
        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            server.daemon_threads = False  # Drain handlers before giving up the root lock.
            token = secrets.token_urlsafe(32)
            server.authorization = ("Bearer " + token).encode()
            server.store = store
            server.pilot = PilotRuns(store, pi_bundle)
            write_json(endpoint, {"port": server.server_port, "token": token})
            try:
                if on_ready:
                    on_ready(store)
                server.serve_forever()
            finally:
                try:
                    server.pilot.close()
                finally:
                    endpoint.unlink(missing_ok=True)
    finally:
        os.close(descriptor)


if __name__ == "__main__":
    def stop(_signal, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--pi-bundle", type=Path, help="Existing application bundle with the embedded Pi runtime")
    parser.add_argument("--audit-helper", type=Path, help="Absolute Swift app executable with audit helper support (defaults to Pi bundle executable)")
    args = parser.parse_args()
    try:
        serve(args.root, pi_bundle=args.pi_bundle, audit_helper=args.audit_helper)
    except (OSError, ValueError, KeyError, TypeError) as error:
        sys.exit("agentxd: " + str(error))
