"""Run one bundled Pi turn on a private loopback model endpoint."""
import ctypes
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import threading
import time
from urllib.parse import urlsplit
import uuid


# macOS proc_pidinfo(PROC_PIDTBSDINFO) uses sys/proc_info.h's proc_bsdinfo.
# Named fields match the Swift AgentXStopProcessIdentity starting-time receipt.
class _BSDInfo(ctypes.Structure):
    _fields_ = [
        ("flags_status_xstatus", ctypes.c_uint32 * 3), ("pid", ctypes.c_uint32),
        ("ppid", ctypes.c_uint32), ("uid", ctypes.c_uint32),
        ("other_ids_reserved", ctypes.c_uint32 * 6), ("comm_name", ctypes.c_char * 48),
        ("counts_tty_nice", ctypes.c_uint32 * 6),
        ("start_seconds", ctypes.c_uint64), ("start_microseconds", ctypes.c_uint64),
    ]


def _identity(pid):
    query = ctypes.CDLL("/usr/lib/libproc.dylib").proc_pidinfo
    query.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int)
    query.restype = ctypes.c_int
    info = _BSDInfo()
    size = ctypes.sizeof(info)
    if query(pid, 3, 0, ctypes.byref(info), size) != size or info.pid != pid or info.uid != os.getuid():
        raise RuntimeError("could not verify Pi process identity")
    return {"pid": pid, "seconds": info.start_seconds, "microseconds": info.start_microseconds}


class PiProcess:
    """One-shot worker. Its owning thread is the only caller of Popen signal/wait APIs."""
    max_input = 1_048_576
    max_output = 131_072
    timeout = 65
    termination_grace = 0.8

    def __init__(self, bundle, base_url, model, messages, *, secret=""):
        bundle = Path(bundle)
        if not bundle.is_absolute() or bundle.suffix != ".app":
            raise ValueError("expected an absolute Pi application bundle")
        url = urlsplit(base_url)
        if (url.scheme != "http" or url.hostname not in ("127.0.0.1", "::1")
                or url.username is not None or url.password is not None or "?" in base_url or "#" in base_url
                or "\\" in base_url or any(ord(ch) < 32 for ch in base_url) or secret):
            raise ValueError("this pilot requires a credential-free numeric loopback endpoint")
        if url.port == 0 or not isinstance(model, str) or not 0 < len(model.strip()) <= 512:
            raise ValueError("invalid pilot model configuration")
        if not isinstance(messages, list) or not 1 <= len(messages) <= 512:
            raise ValueError("invalid Pi messages")
        self.node = bundle / "Contents/Helpers/PiAgent/node"
        self.runner = bundle / "Contents/Resources/PiAgent/runner.mjs"
        request = {"version": 1, "baseURL": base_url, "model": model, "messages": messages, "secret": ""}
        self.payload = json.dumps(request, ensure_ascii=False, allow_nan=False).encode() + b"\n"
        if len(self.payload) > self.max_input:
            raise ValueError("Pi request is too large")
        self._stop = threading.Event()
        self._start = threading.Lock()

    def request_stop(self):
        self._stop.set()

    def _exchange(self, process, evidence):
        data = bytearray()
        remaining = memoryview(self.payload)
        deadline = time.monotonic() + self.timeout
        reason = None
        escalation_at = None
        with selectors.DefaultSelector() as poller:
            os.set_blocking(process.stdin.fileno(), False)
            os.set_blocking(process.stdout.fileno(), False)
            poller.register(process.stdin, selectors.EVENT_WRITE)
            poller.register(process.stdout, selectors.EVENT_READ)
            while True:
                exited = process.poll() is not None
                now = time.monotonic()
                if not exited and reason is None and (self._stop.is_set() or now >= deadline):
                    reason = "stop" if self._stop.is_set() else "timeout"
                    process.terminate()
                    evidence["stopSignal"] = "SIGTERM"
                    escalation_at = now + self.termination_grace
                if not exited and escalation_at is not None and now >= escalation_at:
                    process.kill()
                    evidence["stopSignal"] = "SIGKILL"
                    escalation_at = None
                # On exit drain buffered output, without waiting for an inherited pipe to close.
                ready = poller.select(0 if exited else .025)
                if exited and not ready:
                    break
                for key, _ in ready:
                    stream = key.fileobj
                    if stream is process.stdin:
                        if not exited and reason is None:
                            try:
                                count = os.write(stream.fileno(), remaining[:8192])
                                remaining = remaining[count:]
                                if remaining:
                                    continue
                            except BlockingIOError:
                                continue
                            except BrokenPipeError:
                                pass
                    else:
                        try:
                            chunk = os.read(stream.fileno(), 16384)
                        except BlockingIOError:
                            continue
                        if chunk:
                            if len(data) + len(chunk) > self.max_output:
                                raise ValueError("Pi response exceeded the output limit")
                            data.extend(chunk)
                            continue
                    poller.unregister(stream)
                    stream.close()
        return data, reason

    def run(self, on_launch):
        if not self._start.acquire(blocking=False):
            raise RuntimeError("this Pi worker already ran")
        evidence = {"launchID": str(uuid.uuid4()), "hostPID": os.getpid(), "reaped": False}
        failed = {"status": "failed", "failure": "Pi 运行失败。", "stopEvidence": "unverified",
                  "processEvidence": evidence}
        if self._stop.is_set():
            return dict(failed, status="cancelled", failure="Pi 启动前已取消。")
        try:
            evidence["owner"] = _identity(os.getpid())
            if not self.runner.is_file():
                raise OSError("missing bundled Pi runner")
            process = subprocess.Popen(
                [str(self.node), str(self.runner)], cwd=str(self.runner.parent),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0,
                env={"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": "/private/tmp"},
            )
        except (OSError, RuntimeError):
            return failed

        identified = False
        with process:
            try:
                evidence["childPID"] = process.pid
                evidence["child"] = _identity(process.pid)
                on_launch(dict(evidence))
                identified = True
                output, reason = self._exchange(process, evidence)
            except Exception:
                # A launch receipt failure must prevent request delivery. Do not expose prompts,
                # arbitrary subprocess output or callback exceptions in a persistent run record.
                output, reason = b"", "error"
            finally:
                if process.poll() is None:
                    process.kill()
                evidence["exitCode"] = process.wait()
                evidence["reaped"] = True

        if identified:
            failed["stopEvidence"] = "confirmedExited"
        if reason in ("error", "timeout"):
            if reason == "timeout":
                failed["failure"] = "Pi 运行超时。"
            return failed
        try:
            reply = json.loads(output)
        except (ValueError, UnicodeError):
            reply = {}
        if not isinstance(reply, dict) or reply.get("version") != 1:
            reply = {}
        text = reply.get("text")
        if (evidence["exitCode"] == 0 and reply.get("ok") is True and isinstance(text, str)
                and text.strip() and len(text.encode()) <= 65_536):
            return {"status": "completed", "response": text, "stopEvidence": failed["stopEvidence"],
                    "processEvidence": evidence}
        if (reason == "stop" and "stopSignal" in evidence and
                (evidence["exitCode"] in (-signal.SIGTERM, -signal.SIGKILL) or
                 (evidence["exitCode"] == 0 and (not output or reply.get("code") == "cancelled")))):
            return {"status": "cancelled", "stopEvidence": failed["stopEvidence"], "processEvidence": evidence}
        return failed
