import argparse
import datetime
import http.server
import json
from pathlib import Path
import select
import socket
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--root', required=True, type=Path)
arguments = parser.parse_args()
root = arguments.root
if (root.parent.resolve() != Path('/tmp').resolve()
        or not root.name.startswith('travelcat-native-http-')
        or root.exists() or root.is_symlink()):
    parser.error('root must be a new non-symlink /tmp/travelcat-native-http-* directory')
root.mkdir(mode=0o700)
lock = threading.Lock()
counts = {'text': 0, 'image': 0}

def record(stage, **fields):
    row = {'stage': stage, 'at': datetime.datetime.now().astimezone().isoformat(timespec='milliseconds'), **fields}
    with lock:
        with (root/'ledger.jsonl').open('a') as output:
            output.write(json.dumps(row) + '\n')

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def do_POST(self):
        if self.path == '/__stop':
            self.send_json(200, {'stopped': True})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        length = int(self.headers.get('Content-Length', '0'))
        if length > 16*1024*1024:
            self.send_json(413, {'error': {'message': 'acceptance size limit'}})
            return
        self.rfile.read(length)
        kind = 'image' if '/images/' in self.path else 'text'
        with lock:
            counts[kind] += 1
            index = counts[kind]
        record('received', kind=kind, index=index, path=self.path,
               bodyBytes=length, hasAuthorization='Authorization' in self.headers)
        if kind == 'image':
            self.send_json(503, {'error': {'message': 'synthetic image failure for one-shot recovery acceptance'}})
            record('image-failure-sent', index=index)
            return
        if index == 1:
            deadline = time.monotonic()+180
            while time.monotonic() < deadline:
                ready, _, _ = select.select([self.connection], [], [], 0.2)
                if ready:
                    try:
                        closed = self.connection.recv(1, socket.MSG_PEEK) == b''
                    except OSError:
                        closed = True
                    if closed:
                        record('cancelled-peer-closed', kind=kind, index=index)
                        self.close_connection = True
                        return
            record('delay-expired-without-cancellation', index=index)
        self.send_json(200, {'choices': [{'message': {'content': '{"ok":true}'}}]})
        record('text-success-sent', index=index)
    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
(root/'ready.json').write_text(json.dumps({'port':server.server_port,'host':'127.0.0.1'}))
expiry = threading.Timer(1200, server.shutdown)
expiry.daemon = True
expiry.start()
try:
    server.serve_forever(poll_interval=0.2)
finally:
    expiry.cancel()
    server.server_close()
