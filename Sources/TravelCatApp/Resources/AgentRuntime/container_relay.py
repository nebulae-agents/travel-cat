#!/usr/bin/env python3
"""Unprivileged HTTP-to-stdio transport; no upstream address or credential."""
import base64
import http.server
import json
import os
import queue
import socketserver
import sys
import threading
import uuid

LIMIT=2*1024*1024
RESPONSE_IDLE_TIMEOUT=125
pending={}
lock=threading.Lock()
write_lock=threading.Lock()
slots=threading.BoundedSemaphore(4)

def emit(obj):
    with write_lock:
        sys.stdout.write(json.dumps(obj,separators=(',',':'))+'\n');sys.stdout.flush()

def responses():
    try:
        for line in iter(lambda:sys.stdin.buffer.readline(LIMIT+1),b''):
            if len(line)>LIMIT: break
            obj=json.loads(line)
            with lock: target=pending.get(obj.get('id'))
            if target:
                try: target.put(obj,timeout=5)
                except queue.Full: break
    finally:
        os._exit(1)

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args): pass
    def do_POST(self):
        self.connection.settimeout(30)
        self.close_connection=True
        if not slots.acquire(False): self.send_error(429);return
        rid=uuid.uuid4().hex
        started=False
        try:
            if self.path not in ('/responses','/v1/responses','/messages','/v1/messages','/chat/completions','/v1/chat/completions'):
                self.send_error(403);return
            lengths=self.headers.get_all('Content-Length',[])
            if len(lengths)!=1 or self.headers.get('Transfer-Encoding'):
                self.send_error(400);return
            size=int(lengths[0])
            if size<1 or size>LIMIT//2: self.send_error(413);return
            raw=self.rfile.read(size)
            if len(raw)!=size: self.send_error(400);return
            body=json.loads(raw)
            if not isinstance(body,dict): self.send_error(400);return
            target=queue.Queue(maxsize=16)
            with lock: pending[rid]=target
            emit({'id':rid,'path':self.path,'body':body})
            total=0
            while True:
                item=target.get(timeout=RESPONSE_IDLE_TIMEOUT)
                # Trusted host activity extends idle waiting, without releasing HTTP.
                if item.get('keepalive') is True:continue
                if item.get('error'):
                    if not started: self.send_error(502,'Model request failed')
                    return
                if 'status' in item:
                    if started: return
                    self.send_response(item['status'])
                    self.send_header('Content-Type',item['contentType'])
                    self.send_header('Connection','close');self.end_headers();started=True
                elif 'chunk' in item:
                    if not started: return
                    data=base64.b64decode(item['chunk'],validate=True);total+=len(data)
                    if total>32*1024*1024: return
                    self.wfile.write(data);self.wfile.flush()
                elif item.get('done'): return
        except Exception:
            if not started:
                try: self.send_error(502,'Model request failed')
                except Exception: pass
        finally:
            with lock: pending.pop(rid,None)
            slots.release()

class Server(http.server.ThreadingHTTPServer):
    daemon_threads=True
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name='localhost'
        self.server_port=self.server_address[1]
    request_queue_size=4
    def process_request(self,request,address):
        # Bound connection-handler threads, including idle/malicious connections.
        if not self.connections.acquire(False): request.close();return
        request.settimeout(30)
        try: super().process_request(request,address)
        except Exception: self.connections.release();raise
    def process_request_thread(self,request,address):
        try: super().process_request_thread(request,address)
        finally: self.connections.release()

if __name__=='__main__':
    os.makedirs('/tmp/workspace',mode=0o700,exist_ok=True)
    server=Server(('127.0.0.1',8765),Handler)
    server.connections=threading.BoundedSemaphore(8)
    threading.Thread(target=responses,daemon=True).start()
    emit({'ready':True})
    server.serve_forever()
