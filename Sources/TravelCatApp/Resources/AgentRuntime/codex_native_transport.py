"""Official app-server Unix WebSocket transport; closing a client preserves its daemon."""
import fcntl
import base64
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import select
import signal
import stat
import socket
import struct
import subprocess
import threading
import time
import uuid

MAX_FRAME = 2 * 1024 * 1024
MAX_BYTES = 32 * 1024 * 1024
REQUEST_SECONDS = 30
START_SECONDS = 15
DAEMON_SOCKET_ROOT = Path("/private/tmp" if Path("/private/tmp").is_dir() else "/tmp") / ("codex-daemon-" + str(os.getuid()))


class NativeFailure(Exception):
    pass


def _private_directory(path):
    path = Path(path)
    if not path.exists(): path.mkdir(mode=0o700, parents=True)
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise NativeFailure('native profile or socket directory is not private')


def _read_private(path, maximum=65536):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > maximum:
                raise NativeFailure('invalid native state file')
            with os.fdopen(fd, 'rb', closefd=False) as stream: return stream.read(maximum + 1)
        finally: os.close(fd)
    except OSError:
        raise NativeFailure('native state file unavailable') from None


def _write_new(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb', closefd=False) as stream:
            stream.write(data); stream.flush(); os.fsync(fd)
    finally: os.close(fd)


def _environment(config):
    # Deliberately omit keys, bearer tokens, proxies and all inherited Codex overrides.
    env = {k: v for k, v in os.environ.items() if k in ('HOME', 'LANG', 'LC_ALL', 'USER', 'LOGNAME')}
    env['CODEX_HOME'] = config['profileRoot']
    env['PATH'] = str(Path(config['executable']).parent) + ':/usr/bin:/bin:/usr/sbin:/sbin'
    return env


def _config_text(config, socket_dir):
    quote = lambda s: json.dumps(str(s), ensure_ascii=False)
    return '\n'.join([
        'cli_auth_credentials_store = "keyring"',
        # 0.158 rejects untrusted in TOML but supports it in thread/turn RPCs.
        'approvals_reviewer = "user"',
        'default_permissions = "travelcat-native"', 'web_search = "disabled"',
        '[permissions.travelcat-native]', 'extends = ":workspace"',
        '[permissions.travelcat-native.filesystem]', '":root" = "deny"', '":minimal" = "read"',
        '":tmpdir" = "deny"', '":slash_tmp" = "deny"',
        quote(config['profileRoot']) + ' = "deny"', quote(socket_dir) + ' = "deny"',
        '[permissions.travelcat-native.filesystem.":workspace_roots"]',
        '"." = "write"', '".git" = "read"', '".agents" = "read"', '".codex" = "read"', '".aws" = "read"',
        '[permissions.travelcat-native.network]', 'enabled = false', '',
    ]).encode('utf-8')


def _process_identity(pid):
    if not isinstance(pid, int) or pid <= 1: raise NativeFailure('invalid native daemon identity')
    try:
        result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart=', '-o', 'command='], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3, check=False)
        value = result.stdout.decode('utf-8', errors='replace').strip()
        if result.returncode or not value or len(value) > 32768: return None
        return value
    except (OSError, subprocess.TimeoutExpired):
        raise NativeFailure('cannot verify native daemon process') from None


def _socket_info(path):
    info = path.lstat()
    if info.st_uid != os.getuid(): raise NativeFailure('native daemon socket ownership mismatch')
    if stat.S_ISLNK(info.st_mode):
        # Official 0.158 creates an alias into its per-uid, 0700 socket directory.
        target = Path(os.readlink(path))
        if not target.is_absolute() or target.parent != DAEMON_SOCKET_ROOT or not re.fullmatch(r'[a-f0-9]{64}', target.name):
            raise NativeFailure('native socket alias is outside the official private directory')
        _private_directory(DAEMON_SOCKET_ROOT)
        target_info = target.lstat()
        if not stat.S_ISSOCK(target_info.st_mode) or target_info.st_uid != os.getuid() or stat.S_IMODE(target_info.st_mode) != 0o600:
            raise NativeFailure('native socket alias target ownership mismatch')
    elif not stat.S_ISSOCK(info.st_mode):
        raise NativeFailure('native daemon socket ownership mismatch')
    return info


def _ensure_daemon(config):
    profile = Path(config['profileRoot'])
    _private_directory(profile)
    digest = hashlib.sha256(str(profile).encode()).hexdigest()[:24]
    socket_dir = Path('/private/tmp' if Path('/private/tmp').is_dir() else '/tmp') / ('tc-native-' + str(os.getuid()) + '-' + digest)
    _private_directory(socket_dir)
    sock = socket_dir / 'server.sock'
    lock_path = profile / 'travelcat-daemon.lock'
    fd = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid(): raise NativeFailure('invalid native daemon lock')
        deadline = time.monotonic() + START_SECONDS
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline: raise NativeFailure('native daemon startup lock timed out')
                time.sleep(0.05)
        content = _config_text(config, socket_dir)
        config_file = profile / 'config.toml'
        if config_file.exists() or config_file.is_symlink():
            if _read_private(config_file) != content: raise NativeFailure('native profile configuration changed; reconnect refused')
        else: _write_new(config_file, content)
        expected = {'profileRoot': str(profile), 'workspace': config['workspace'], 'executable': config['executable'], 'socket': str(sock), 'configHash': hashlib.sha256(content).hexdigest()}
        receipt_file = profile / 'travelcat-daemon.json'
        receipt = None
        if receipt_file.exists() or receipt_file.is_symlink():
            try: receipt = json.loads(_read_private(receipt_file))
            except (ValueError, UnicodeError): raise NativeFailure('invalid native daemon receipt') from None
            if not isinstance(receipt, dict) or any(receipt.get(k) != v for k, v in expected.items()): raise NativeFailure('native daemon receipt identity mismatch')
            identity = _process_identity(receipt.get('pid'))
            if identity is not None:
                if identity != receipt.get('processIdentity') or str(sock) not in identity or 'app-server' not in identity:
                    raise NativeFailure('native daemon process identity mismatch')
                if not sock.exists() or _socket_info(sock).st_ino != receipt.get('socketInode'): raise NativeFailure('native daemon socket changed')
                return str(sock)
            # Remove only the stale socket proven by our receipt and inode.
            if sock.exists() or sock.is_symlink():
                if _socket_info(sock).st_ino != receipt.get('socketInode'): raise NativeFailure('unowned native socket at expected path')
                sock.unlink()
            receipt_file.unlink()
        elif sock.exists() or sock.is_symlink():
            raise NativeFailure('native socket has no ownership receipt')
        try:
            daemon = subprocess.Popen([config['executable'], 'app-server', '--listen', 'unix://' + str(sock)], cwd=str(profile), env=_environment(config), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
        except OSError:
            raise NativeFailure('native Codex server could not start') from None
        # Keep a reference so subprocess does not warn on successful detached lifetime.
        _DAEMONS.append(daemon)
        try:
            while not sock.exists():
                if daemon.poll() is not None: raise NativeFailure('native Codex server exited before readiness')
                if time.monotonic() >= deadline: raise NativeFailure('native Codex server startup timed out')
                time.sleep(0.05)
            info = _socket_info(sock)
            identity = _process_identity(daemon.pid)
            if not identity or str(sock) not in identity or 'app-server' not in identity: raise NativeFailure('native daemon identity could not be verified')
            receipt = {**expected, 'pid': daemon.pid, 'processIdentity': identity, 'socketInode': info.st_ino}
            _write_new(receipt_file, json.dumps(receipt, sort_keys=True).encode())
            return str(sock)
        except Exception:
            # A failed launch has never accepted a product turn. Reap only this
            # newly spawned process/group, never a PID taken from a receipt.
            owned_inode = None
            try: owned_inode = _socket_info(sock).st_ino
            except (OSError, NativeFailure): pass
            if daemon.poll() is None:
                try:
                    if os.getpgid(daemon.pid) == daemon.pid: os.killpg(daemon.pid, signal.SIGTERM)
                    else: daemon.terminate()
                except ProcessLookupError: pass
                try: daemon.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    daemon.kill(); daemon.wait(timeout=2)
            if owned_inode is not None:
                try:
                    if sock.lstat().st_ino == owned_inode: sock.unlink()
                except FileNotFoundError: pass
            raise
    finally:
        os.close(fd)


_DAEMONS = []


class NativeTransport:
    """Bounded RFC6455 client for the official local Unix socket only."""
    def __init__(self, config, callback):
        self.callback, self.pending = callback, {}
        self.lock, self.writer = threading.RLock(), threading.Lock()
        self.closed, self.total = False, 0
        path = _ensure_daemon(config)
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(START_SECONDS)
        try:
            self.socket.connect(path)
            self.socket.setblocking(False)
            self._handshake()
        except (OSError, ValueError, NativeFailure):
            self.socket.close()
            raise NativeFailure('native WebSocket handshake failed') from None
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _handshake(self):
        key = base64.b64encode(os.urandom(16))
        request = b'GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ' + key + b'\r\n\r\n'
        deadline = time.monotonic() + START_SECONDS
        self._write_bytes(request, deadline)
        header = bytearray()
        while not header.endswith(b'\r\n\r\n'):
            if len(header) >= 16384 or time.monotonic() > deadline: raise NativeFailure('invalid WebSocket handshake')
            part = self._exact(1, deadline)
            if not part: raise NativeFailure('native WebSocket closed during handshake')
            header.extend(part)
        lines = bytes(header).split(b'\r\n')
        if lines[0].split(b' ')[:2] != [b'HTTP/1.1', b'101']: raise NativeFailure('native WebSocket upgrade rejected')
        headers = {}
        for line in lines[1:]:
            if not line: continue
            name, sep, value = line.partition(b':')
            if not sep or name.lower() in headers: raise NativeFailure('ambiguous WebSocket handshake')
            headers[name.lower()] = value.strip()
        accept = base64.b64encode(hashlib.sha1(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
        if headers.get(b'sec-websocket-accept') != accept or headers.get(b'upgrade', b'').lower() != b'websocket' or b'upgrade' not in [v.strip().lower() for v in headers.get(b'connection', b'').split(b',')] or b'sec-websocket-extensions' in headers:
            raise NativeFailure('invalid WebSocket upgrade response')

    def _write_bytes(self, data, deadline):
        # Select readiness is advisory: nonblocking I/O is essential under backpressure.
        self.socket.setblocking(False)
        offset = 0
        try:
            while offset < len(data):
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([], [self.socket], [], remaining)[1]: raise NativeFailure('native socket write timed out')
                try: sent = self.socket.send(data[offset:offset + 16384])
                except (BlockingIOError, InterruptedError): continue
                if not sent: raise NativeFailure('native socket closed during write')
                offset += sent
        except (OSError, ValueError): raise NativeFailure('native socket write failed') from None

    def _wire_send(self, payload, opcode=1):
        if len(payload) > MAX_FRAME: raise NativeFailure('native request exceeds frame limit')
        key = os.urandom(4)
        if len(payload) < 126: header = bytes([128 | opcode, 128 | len(payload)])
        elif len(payload) < 65536: header = bytes([128 | opcode, 254]) + struct.pack('!H', len(payload))
        else: header = bytes([128 | opcode, 255]) + struct.pack('!Q', len(payload))
        data = header + key + bytes(b ^ key[i % 4] for i, b in enumerate(payload))
        deadline = time.monotonic() + REQUEST_SECONDS
        if not self.writer.acquire(timeout=REQUEST_SECONDS): raise NativeFailure('native socket writer timed out')
        try:
            if self.closed: raise NativeFailure('native socket disconnected')
            self._write_bytes(data, deadline)
        finally: self.writer.release()

    def _send(self, value):
        self._wire_send(json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode())

    def request(self, method, params):
        request_id = str(uuid.uuid4())
        response = queue.Queue(maxsize=1)
        with self.lock:
            if self.closed: raise NativeFailure('native socket disconnected')
            if len(self.pending) >= 32: raise NativeFailure('too many native requests')
            self.pending[request_id] = response
        try:
            try: self._send({'id': request_id, 'method': method, 'params': params})
            except NativeFailure:
                self._lost()
                raise
            try: result = response.get(timeout=REQUEST_SECONDS)
            except queue.Empty:
                self._lost()
                raise NativeFailure('native request timed out; outcome unknown, resume before retrying') from None
            if isinstance(result, NativeFailure): raise result
            if 'error' in result: raise NativeFailure('native server rejected ' + method)
            if not isinstance(result.get('result'), dict): raise NativeFailure('invalid native server response')
            return result['result']
        finally:
            with self.lock: self.pending.pop(request_id, None)

    def notify(self, method, params): self._send({'method': method, 'params': params})

    def respond(self, request_id, result=None, error=None):
        self._send({'id': request_id, **({'error': error} if error is not None else {'result': result})})

    def _exact(self, count, deadline=None):
        data = bytearray()
        while len(data) < count:
            if self.closed: raise NativeFailure('native socket disconnected')
            remaining = deadline - time.monotonic() if deadline is not None else 1
            if remaining <= 0: raise NativeFailure('native frame read timed out')
            try:
                ready = select.select([self.socket], [], [], remaining)[0]
                if not ready:
                    if deadline is not None: raise NativeFailure('native frame read timed out')
                    continue
                try: part = self.socket.recv(min(count - len(data), 65536))
                except (BlockingIOError, InterruptedError): continue
            except (OSError, ValueError): raise NativeFailure('native socket read failed') from None
            if not part: raise NativeFailure('native socket disconnected')
            if deadline is None: deadline = time.monotonic() + REQUEST_SECONDS
            data.extend(part)
        return bytes(data)

    def _message(self):
        data, fragments, started, deadline = bytearray(), 0, False, None
        while True:
            h = self._exact(2, deadline)
            if deadline is None: deadline = time.monotonic() + REQUEST_SECONDS
            final, opcode, size = bool(h[0] & 128), h[0] & 15, h[1] & 127
            if h[0] & 112 or h[1] & 128: raise NativeFailure('invalid native WebSocket frame')
            if size == 126: size = struct.unpack('!H', self._exact(2, deadline))[0]
            elif size == 127: size = struct.unpack('!Q', self._exact(8, deadline))[0]
            if size > MAX_FRAME or len(data) + size > MAX_FRAME: raise NativeFailure('native frame exceeds limit')
            self.total += size + 2
            if self.total > MAX_BYTES: raise NativeFailure('native output exceeds connection limit')
            if opcode >= 8:
                if not final or size > 125: raise NativeFailure('invalid native WebSocket control frame')
                payload = self._exact(size, deadline)
                if opcode == 8:
                    if len(payload) == 1: raise NativeFailure('invalid native WebSocket close')
                    self._wire_send(payload, 8)
                    raise NativeFailure('native server closed connection')
                if opcode == 9: self._wire_send(payload, 10)
                elif opcode != 10: raise NativeFailure('unsupported native WebSocket control frame')
                if not started: deadline = None
                continue
            if opcode not in (0, 1) or (opcode == 0 and not started) or (opcode == 1 and started): raise NativeFailure('unsupported native WebSocket message')
            started = True
            fragments += 1
            if fragments > 1024: raise NativeFailure('too many native WebSocket fragments')
            data.extend(self._exact(size, deadline))
            if final: return bytes(data)

    def _read(self):
        try:
            while not self.closed:
                frame = json.loads(self._message().decode('utf-8'))
                if not isinstance(frame, dict): break
                if 'method' in frame:
                    if not isinstance(frame['method'], str): break
                    self.callback(frame)
                elif 'id' in frame:
                    with self.lock: target = self.pending.get(frame['id'])
                    if target:
                        try: target.put_nowait(frame)
                        except queue.Full: break
                else: break
        except (OSError, ValueError, TypeError, NativeFailure): pass
        finally: self._lost()

    def _lost(self):
        with self.lock:
            if self.closed: return
            self.closed = True
            pending = list(self.pending.values())
        self._stop_client()
        try:
            self.callback({'method': 'connection/lost', 'params': {}})
        finally:
            for target in pending:
                try: target.put_nowait(NativeFailure('native socket disconnected; turn outcome unknown'))
                except queue.Full: pass

    def _stop_client(self):
        try: self.socket.shutdown(socket.SHUT_RDWR)
        except OSError: pass
        self.socket.close()

    def close(self):
        with self.lock:
            if self.closed: return
            self.closed = True
            for target in self.pending.values():
                try: target.put_nowait(NativeFailure('native client detached'))
                except queue.Full: pass
        self._stop_client()
