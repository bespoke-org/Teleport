#!/usr/bin/env python3
"""Exercise a Teleport-generated config on loopback, without helper/network changes.

The client config comes from XrayConfigurationWriter in XrayGroupIntegrationTests.
Two real VLESS servers redirect to independent HTTP origins identifying A and B.
The request's original destination is a third origin identifying DIRECT, so an
accidental direct fallback is observable even when both proxy servers are down.
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


class Lab:
    def __init__(self, binary, config_path):
        self.binary = binary
        self.directory = config_path.parent
        self.config_path = config_path
        self.config = json.loads(config_path.read_text())
        self.children = []
        self.origins = []
        self.logs = []
        self.direct_requests = []
        self.members = [o for o in self.config["outbounds"] if o["protocol"] == "vless"]
        self.http_port = next(i["port"] for i in self.config["inbounds"] if i["protocol"] == "http")
        self.destination = self.config["burstObservatory"]["pingConfig"]["destination"].rsplit("/", 1)[0]

    def origin(self, label, port=0):
        lab = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if label == "DIRECT":
                    lab.direct_requests.append(self.path)
                data = label.encode()
                self.send_response(204 if self.path == "/probe" else 200)
                self.send_header("Content-Length", "0" if self.path == "/probe" else str(len(data)))
                self.end_headers()
                if self.path != "/probe":
                    with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                        self.wfile.write(data)

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.origins.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server.server_port

    def launch(self, name, config_path, port):
        log = open(self.directory / (name + ".log"), "ab", buffering=0)
        self.logs.append(log)
        process = subprocess.Popen([self.binary, "run", "-config", str(config_path)], stdout=log, stderr=log)
        self.children.append(process)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            assert process.poll() is None, f"{name} exited: {(self.directory / (name + '.log')).read_text()}"
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    return process
            except OSError:
                time.sleep(0.05)
        raise AssertionError(f"{name} did not listen on loopback")

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)

    def member(self, index, origin_port):
        endpoint = self.members[index]["settings"]["vnext"][0]
        config = {
            "log": {"loglevel": "warning"},
            "inbounds": [{"listen": "127.0.0.1", "port": endpoint["port"], "protocol": "vless",
                          "settings": {"clients": [{"id": endpoint["users"][0]["id"]}], "decryption": "none"},
                          "streamSettings": {"network": "tcp", "security": "none"}}],
            "outbounds": [{"protocol": "freedom", "settings": {"redirect": f"127.0.0.1:{origin_port}",
                           # Xray blocks private destinations by default for
                           # server inbounds. Only this loopback lab needs access.
                           "finalRules": [{"action": "allow", "ip": ["127.0.0.1/32"]}]}}],
        }
        path = self.directory / f"member-{index}.json"
        path.write_text(json.dumps(config))
        return self.launch(f"member-{index}", path, endpoint["port"])

    def request(self, via_proxy=True):
        # Ignore environment proxy/no_proxy settings, including localhost bypasses.
        proxy = f"http://127.0.0.1:{self.http_port}" if via_proxy else ""
        result = subprocess.run(["/usr/bin/curl", "--silent", "--show-error", "--fail", "--max-time", "1",
                                 "--noproxy", "", "--proxy", proxy, self.destination + "/request"],
                                capture_output=True, text=True, timeout=2)
        return result.returncode, result.stdout

    def await_member(self, label):
        deadline = time.monotonic() + 20
        last = None
        while time.monotonic() < deadline:
            last = self.request()
            assert last[1] != "DIRECT", "Request bypassed the proxy group"
            if last == (0, label):
                print(f"Traffic reached member {label}", flush=True)
                return
            time.sleep(0.1)
        raise AssertionError(f"Group did not select {label}: last response {last}")

    def run(self):
        direct_port = int(self.destination.rsplit(":", 1)[1])
        self.origin("DIRECT", direct_port)
        a_origin, b_origin = self.origin("A"), self.origin("B")
        # Prove the canary would answer a request that escaped the proxy group.
        assert self.request(via_proxy=False) == (0, "DIRECT")
        self.direct_requests.clear()
        a = self.member(0, a_origin)
        client = self.launch("client", self.config_path, self.http_port)
        self.await_member("A")
        b = self.member(1, b_origin)
        self.stop(a)
        self.await_member("B")
        self.stop(b)
        # Keep the origins alive: success here would expose a direct fallback.
        deadline = time.monotonic() + 12  # Cover a complete 10s observer cycle.
        while time.monotonic() < deadline:
            code, body = self.request()
            assert code != 0 and not body, f"All members down but request succeeded: {code}, {body!r}"
            time.sleep(0.3)
        print("All members down: requests failed without direct traffic", flush=True)
        # Recover the non-fallback member. A remains down, so stale selection or
        # always using fallback A cannot accidentally pass the recovery check.
        self.member(1, b_origin)
        self.await_member("B")
        assert not self.direct_requests, f"Group bypassed proxies: {self.direct_requests}"
        self.stop(client)
        assert self.request()[0] != 0, "Client still accepted requests after shutdown"
        print("Recovery and client shutdown verified", flush=True)

    def close(self):
        for child in reversed(self.children):
            self.stop(child)
        for origin in self.origins:
            origin.shutdown()
            origin.server_close()
        for log in self.logs:
            log.close()
        assert all(child.poll() is not None for child in self.children), "An Xray child survived cleanup"


def interrupted(*_):
    raise RuntimeError("Integration test interrupted")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    lab = Lab(sys.argv[1], pathlib.Path(sys.argv[2]))
    try:
        lab.run()
    except Exception:
        for path in lab.directory.glob("*.log"):
            if path.name != "lab.log":
                print(f"{path.name}:\n{path.read_text()[-6000:]}", file=sys.stderr)
        raise
    finally:
        lab.close()
