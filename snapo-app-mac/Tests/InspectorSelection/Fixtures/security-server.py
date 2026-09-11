"""Synthetic loopback endpoints for the native WebView security tests."""

import base64
import faulthandler
import hashlib
import http.server
import json
import pathlib
import socketserver
import sys
import threading

root = pathlib.Path(sys.argv[1])
lock = threading.Lock()
requests = []
connections = []


class Server(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # These endpoints use IP literals; startup must not wait for reverse DNS.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

    def get_request(self):
        connection, address = super().get_request()
        with lock:
            connections.append(self.server_port)
        return connection, address


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_OPTIONS(self):
        self.respond(204, b"")

    def do_POST(self):
        self.do_GET()

    def respond(self, status, body, content_type="text/plain", extra=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path == "/connections":
            with lock:
                body = json.dumps(connections).encode()
            self.respond(200, body, "application/json")
            return
        if self.path == "/requests":
            with lock:
                body = json.dumps(requests).encode()
            self.respond(200, body, "application/json")
            return
        with lock:
            requests.append({"port": self.server.server_port, "path": self.path})
        if self.path == "/dev":
            self.respond(200, b'<script type="module" src="/dev.js"></script>', "text/html")
        elif self.path == "/dev.js":
            self.respond(200, b'window.devLoaded = true; const ws = new WebSocket(location.origin.replace("http", "ws") + "/hmr"); ws.onmessage = e => { window.hmr = e.data; ws.close(); };', "text/javascript")
        elif self.path == "/redirect":
            self.respond(302, b"", extra={"Location": f"http://127.0.0.1:{denied.server_port}/redirected"})
        elif self.headers.get("Upgrade", "").lower() == "websocket":
            digest = hashlib.sha1((self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", base64.b64encode(digest).decode())
            self.end_headers()
            self.wfile.write(b"\x81\x02ok")
            self.wfile.flush()
        elif self.path == "/events":
            self.respond(200, b"data: ok\n\n", "text/event-stream")
        else:
            self.respond(200, b"ok")


faulthandler.dump_traceback_later(10, exit=True)
allowed = Server(("127.0.0.1", 0), Handler)
denied = Server(("127.0.0.1", 0), Handler)
for server in (allowed, denied):
    threading.Thread(target=server.serve_forever, daemon=True).start()
ports = root / "ports.json"
temporary = root / "ports.tmp"
temporary.write_text(json.dumps({"allowed": allowed.server_port, "denied": denied.server_port}))
temporary.replace(ports)
faulthandler.cancel_dump_traceback_later()
threading.Event().wait()
