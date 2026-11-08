#!/usr/bin/env python3
"""Observe generated FinalMask settings on loopback, without changing OS networking."""
import copy
import json
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def listener():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sock.listen()
    sock.settimeout(5)
    return sock


def read_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise AssertionError("Proxy closed before sending a complete ClientHello")
        data.extend(chunk)
    return bytes(data)


def capture(executable, original, fragmented):
    config = copy.deepcopy(original)
    with listener() as remote, listener() as http, listener() as socks:
        remote_port = remote.getsockname()[1]
        http_port = http.getsockname()[1]
        socks_port = socks.getsockname()[1]
        for inbound in config["inbounds"]:
            inbound["listen"] = "127.0.0.1"
            inbound["port"] = http_port if inbound["protocol"] == "http" else socks_port
        proxy = next(outbound for outbound in config["outbounds"] if outbound["protocol"] == "vless")
        proxy["settings"]["vnext"][0].update(address="127.0.0.1", port=remote_port)
        if not fragmented:
            proxy["streamSettings"].pop("finalmask")
        # Keep only this synthetic proxy: no fallback can contact an external host.
        config["outbounds"] = [proxy]
        config["routing"] = {"domainStrategy": "AsIs", "rules": []}
        config.pop("dns", None)
        with tempfile.TemporaryDirectory(prefix="teleport-fragment-") as directory:
            path = Path(directory) / "client.json"
            path.write_text(json.dumps(config))
            http.close()
            socks.close()
            with open(Path(directory) / "xray.log", "w+") as log:
                process = subprocess.Popen([executable, "run", "-config", str(path)], stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 5
                    while True:
                        if process.poll() is not None:
                            raise AssertionError("Xray exited before accepting a request")
                        try:
                            request = socket.create_connection(("127.0.0.1", http_port), timeout=0.2)
                            break
                        except OSError:
                            if time.monotonic() >= deadline:
                                raise AssertionError("Xray HTTP listener did not start")
                            time.sleep(0.02)
                    with request:
                        request.sendall(b"GET http://destination.example.test/ HTTP/1.1\r\nHost: destination.example.test\r\nConnection: close\r\n\r\n")
                        conn, _ = remote.accept()
                        with conn:
                            conn.settimeout(5)
                            records, handshake = [], bytearray()
                            while True:
                                header = read_exact(conn, 5)
                                assert header[0] == 22, "Expected TLS handshake records"
                                length = int.from_bytes(header[3:5], "big")
                                assert 0 < length <= 16384, "Invalid TLS record length"
                                records.append(length)
                                handshake.extend(read_exact(conn, length))
                                assert len(handshake) <= 65536, "Unexpectedly large ClientHello"
                                if len(handshake) >= 4:
                                    assert handshake[0] == 1, "Expected ClientHello"
                                    if len(handshake) >= 4 + int.from_bytes(handshake[1:4], "big"):
                                        break
                            if fragmented:
                                assert len(records) > 1 and all(10 <= n <= 20 for n in records[:-1]) and records[-1] <= 20, records
                            else:
                                assert len(records) == 1 and records[0] > 20, records
                            return len(records)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=3)


if __name__ == "__main__":
    executable, config_path = sys.argv[1:]
    config = json.loads(Path(config_path).read_text())
    baseline = capture(executable, config, False)
    fragmented = capture(executable, config, True)
    print(f"PASS: baseline {baseline} TLS record; configured mask emitted {fragmented} bounded fragments; Xray reaped")
