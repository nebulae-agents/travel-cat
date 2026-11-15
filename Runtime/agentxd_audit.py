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

    def __init__(self, root, app, executable):
        from pathlib import Path
        import os
        import stat
        self.executable = Path(executable)
        info = self.executable.lstat()
        if (not self.executable.is_absolute() or self.executable.resolve() != self.executable
                or not stat.S_ISREG(info.st_mode) or info.st_mode & 0o022
                or info.st_uid not in (0, os.getuid()) or not os.access(self.executable, os.X_OK)):
            raise ValueError('invalid audit helper')
        self.arguments = [str(self.executable), '--agentx-audit-helper', '--root', str(root), '--app', app]

    def call(self, request):
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
        rows = self.call({'op': 'records', 'runId': run_id}).get('records')
        if not isinstance(rows, list):
            raise ValueError('audit helper unavailable')
        return rows

    def verify(self):
        count = self.call({'op': 'verify'}).get('records')
        if type(count) is not int or count < 0:
            raise ValueError('audit helper unavailable')
        return count
