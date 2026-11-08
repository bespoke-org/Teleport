#!/usr/bin/env python3
"""Local-only Xray fixture: a working proxy or a server rejecting TLS.

Print the proxy and origin ports, then wait for stdin to close. Never changes
system proxies, routes, DNS, or the installed privileged helper.
"""
import contextlib
import http.server
import json
import pathlib
import signal
import socket
import subprocess
import sys
import threading
import time


class Origin(http.server.BaseHTTPRequestHandler):
    def handle(self):
        if self.connection.recv(1, socket.MSG_PEEK) == b"\x16":
            (directory / "tls-attempted").touch()
        super().handle()

    def do_HEAD(self):
        self.send_response(403 if self.path == "/blocked" else 204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_):
        pass


def end(*_):
    raise SystemExit(0)


signal.signal(signal.SIGTERM, end)
signal.signal(signal.SIGALRM, end)
signal.alarm(30)
binary, directory, mode = sys.argv[1:]
directory = pathlib.Path(directory)
origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin)
threading.Thread(target=origin.serve_forever, daemon=True).start()
with contextlib.closing(socket.socket()) as reservation:
    reservation.bind(("127.0.0.1", 0))
    proxy_port = reservation.getsockname()[1]
outbound = {"protocol": "freedom", "settings": {"finalRules": [{"action": "allow", "ip": ["127.0.0.1/32"]}]}}
if mode == "bad-handshake":
    # A plain HTTP origin cannot complete the TLS handshake required by VLESS.
    outbound = {
        "protocol": "vless",
        "settings": {"vnext": [{"address": "127.0.0.1", "port": origin.server_port,
            "users": [{"id": "123e4567-e89b-12d3-a456-426614174000", "encryption": "none"}]}]},
        "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "localhost"}},
    }
config = {
    "log": {"loglevel": "warning"},
    "inbounds": [{"listen": "127.0.0.1", "port": proxy_port, "protocol": "http", "settings": {}}],
    "outbounds": [outbound],
}
config_path = directory / "client.json"
config_path.write_text(json.dumps(config))
with open(directory / "xray.log", "wb") as log:
    child = subprocess.Popen([binary, "run", "-c", str(config_path)], stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 5
        while True:
            if child.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("Fixture Xray did not start")
            try:
                with socket.create_connection(("127.0.0.1", proxy_port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.02)
        print(json.dumps({"proxyPort": proxy_port, "originPort": origin.server_port}), flush=True)
        sys.stdin.readline()
    finally:
        child.terminate()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        origin.shutdown()
