"""Metadata-only audit outbox. The Swift helper owns encryption and credentials."""
import datetime
import uuid


def enqueue(run, phase):
    context = run.get('auditContext')
    if context is None:
        return  # Never invent audit events for legacy history.
    event_id = str(uuid.uuid5(uuid.UUID(run['id']), 'agentxd-audit-v1/' + phase))
    if any(row['eventId'] == event_id for row in run.get('auditOutbox', [])):
        return
    record = dict(context, eventId=event_id, taskId=run['id'], appId=run['appID'],
                  instanceId=run['instanceID'], kind='model.request.' + phase,
                  timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z'))
    if phase in ('completed', 'failed', 'cancelled'):
        record.update(status=phase, responseBytes=len(run.get('response', '').encode()))
    run.setdefault('auditOutbox', []).append(record)
    run['auditStatus'] = 'pending'
    run['auditFailure'] = '审计尚未确认，服务将在恢复时重试。'


class SwiftAudit:
    max_output = 4 * 1024 * 1024
    timeout = 12
    startup_timeout = 60

    def __init__(self, root, app, executable, *, persistent=False):
        from pathlib import Path
        import os
        import stat
        self.executable = Path(executable)
        info = self.executable.lstat()
        if (not self.executable.is_absolute() or self.executable.resolve() != self.executable
                or not stat.S_ISREG(info.st_mode) or info.st_mode & 0o022
                or info.st_uid not in (0, os.getuid()) or not os.access(self.executable, os.X_OK)):
            raise ValueError('invalid audit helper')
        import threading
        self.persistent = persistent
        self.process = None
        self.closed = False
        self.lock = threading.RLock()
        self.buffer = bytearray()
        self.failure_category = None
        mode = '--agentx-audit-session' if persistent else '--agentx-audit-helper'
        self.arguments = [str(self.executable), mode, '--root', str(root), '--app', app]
        if persistent:
            import os
            import subprocess
            import time
            try:
                self.process = subprocess.Popen(self.arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                                stderr=subprocess.DEVNULL, close_fds=True)
                os.set_blocking(self.process.stdin.fileno(), False)
                os.set_blocking(self.process.stdout.fileno(), False)
                if self._read_frame(time.monotonic() + self.startup_timeout) != {'ok': True, 'ready': True}:
                    raise ValueError()
            except BaseException as error:
                self.close()
                if isinstance(error, (OSError, ValueError, subprocess.TimeoutExpired)):
                    raise ValueError('audit helper unavailable') from None
                raise

    def _read_frame(self, deadline):
        import json
        import os
        import selectors
        import time
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while True:
                newline = self.buffer.find(b'\n')
                if newline >= 0:
                    if newline > self.max_output:
                        self.failure_category = 'output_limit'
                        raise ValueError()
                    frame = bytes(self.buffer[:newline])
                    del self.buffer[:newline + 1]
                    return json.loads(frame)
                if len(self.buffer) > self.max_output:
                    self.failure_category = 'output_limit'
                    raise ValueError()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self.failure_category = 'timeout'
                    raise ValueError()
                if selector.select(min(.05, remaining)):
                    data = os.read(self.process.stdout.fileno(), 8192)
                    if not data:
                        self.failure_category = 'exited'
                        raise ValueError()
                    self.buffer.extend(data)

    def _session_call(self, request):
        import json
        import os
        import selectors
        import time
        with self.lock:
            try:
                if self.closed:
                    raise ValueError()
                payload = json.dumps(request, allow_nan=False).encode()
                if len(payload) > 16 * 1024:
                    raise ValueError()
                remaining = memoryview(payload + b'\n')
                deadline = time.monotonic() + self.timeout
                with selectors.DefaultSelector() as selector:
                    selector.register(self.process.stdin, selectors.EVENT_WRITE)
                    while remaining:
                        budget = deadline - time.monotonic()
                        if budget <= 0:
                            self.failure_category = 'timeout'
                            raise ValueError()
                        if selector.select(min(.05, budget)):
                            count = os.write(self.process.stdin.fileno(), remaining[:4096])
                            remaining = remaining[count:]
                result = self._read_frame(deadline)
                if not isinstance(result, dict) or result.get('ok') is not True:
                    raise ValueError()
                return result
            except (OSError, ValueError, TypeError):
                self.close()
                raise ValueError('audit helper unavailable') from None

    def close(self):
        import subprocess
        with self.lock:
            if self.closed:
                return
            self.closed = True
            if self.process is None:
                return
            try:
                self.process.stdin.close()
                self.process.wait(timeout=2)
            except (OSError, subprocess.TimeoutExpired):
                if self.process.poll() is None:
                    self.process.kill()
                self.process.wait()
            finally:
                self.process.stdout.close()

    def call(self, request):
        if self.persistent:
            return self._session_call(request)
        import json
        import os
        import selectors
        import subprocess
        import time
        payload = json.dumps(request, allow_nan=False).encode()
        if len(payload) > 16 * 1024:
            raise ValueError('audit helper unavailable')
        try:
            with subprocess.Popen(self.arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, close_fds=True) as process:
                try:
                    output = bytearray()
                    remaining = memoryview(payload)
                    deadline = time.monotonic() + self.timeout
                    with selectors.DefaultSelector() as selector:
                        for stream, events in ((process.stdin, selectors.EVENT_WRITE), (process.stdout, selectors.EVENT_READ)):
                            os.set_blocking(stream.fileno(), False)
                            selector.register(stream, events)
                        while selector.get_map():
                            if time.monotonic() >= deadline:
                                raise ValueError()
                            for key, _ in selector.select(.05):
                                stream = key.fileobj
                                if stream is process.stdin:
                                    sent = os.write(stream.fileno(), remaining[:4096])
                                    remaining = remaining[sent:]
                                    if not remaining:
                                        selector.unregister(stream)
                                        stream.close()
                                else:
                                    data = os.read(stream.fileno(), 8192)
                                    output.extend(data)
                                    if len(output) > self.max_output:
                                        raise ValueError()
                                    if not data:
                                        selector.unregister(stream)
                    if process.wait(timeout=max(.01, deadline-time.monotonic())) != 0:
                        raise ValueError()
                    result = json.loads(output)
                    if not isinstance(result, dict) or result.get('ok') is not True:
                        raise ValueError()
                    return result
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.wait()
        except (OSError, ValueError, subprocess.TimeoutExpired):
            raise ValueError('audit helper unavailable') from None

    def append(self, record):
        self.call({'op': 'append', 'record': record})

    def records(self, run_id):
        # Legacy records may have non-UUID IDs, which the Swift bridge cannot look up.
        try:
            if str(uuid.UUID(run_id)) != run_id.lower():
                return []
        except ValueError:
            return []
        rows = self.call({'op': 'records', 'runId': run_id}).get('records')
        if not isinstance(rows, list):
            raise ValueError('audit helper unavailable')
        return rows

    def verify(self):
        count = self.call({'op': 'verify'}).get('records')
        if type(count) is not int or count < 0:
            raise ValueError('audit helper unavailable')
        return count
