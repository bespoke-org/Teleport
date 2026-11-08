#!/usr/bin/env python3
"""Validate generated configs and exercise their Shadowsocks outbounds on loopback.

System Proxy uses the generated listeners. TUN configs are validated unchanged,
then their proxy outbound is exercised with SOCKS listeners instead of a real
utun. This verifies interface binding and protocol behavior without root access
or changes to the host's routes, DNS, helper, or system proxy settings.
"""
import contextlib
import copy
import json
import pathlib
import signal
import socket
import struct
import subprocess
import sys
import threading
import time


def receive(sock, length):
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        assert chunk, "Unexpected SOCKS EOF"
        data += chunk
    return data


def reply_address(sock):
    version, status, _, kind = receive(sock, 4)
    assert version == 5 and status == 0, "SOCKS request failed"
    assert kind == 1, "Expected a loopback IPv4 SOCKS endpoint"
    return socket.inet_ntoa(receive(sock, 4)), struct.unpack("!H", receive(sock, 2))[0]


class Lab:
    def __init__(self, binary, directory):
        self.binary, self.directory = binary, directory
        self.children, self.logs = [], []
        self.tcp = socket.socket()
        self.tcp.bind(("127.0.0.1", 0))
        self.tcp.listen()
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind(self.tcp.getsockname())
        threading.Thread(target=self.tcp_echo, daemon=True).start()
        threading.Thread(target=self.udp_echo, daemon=True).start()

    def tcp_echo(self):
        while True:
            try:
                conn, _ = self.tcp.accept()
            except OSError:
                return
            with conn:
                conn.settimeout(3)
                with contextlib.suppress(OSError):
                    data = conn.recv(4096)
                    conn.sendall(data)

    def udp_echo(self):
        while True:
            try:
                data, address = self.udp.recvfrom(4096)
                self.udp.sendto(data, address)
            except OSError:
                return

    def launch(self, name, config, port):
        path = self.directory / (name + ".json")
        path.write_text(json.dumps(config))
        log = open(self.directory / (name + ".log"), "ab", buffering=0)
        self.logs.append(log)
        process = subprocess.Popen([self.binary, "run", "-c", str(path)], stdout=log, stderr=log)
        self.children.append(process)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            assert process.poll() is None, f"{name} exited before listening"
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    return process
            except OSError:
                time.sleep(0.03)
        raise AssertionError(f"{name} did not listen")

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)

    @staticmethod
    def socks(port, command):
        sock = socket.create_connection(("127.0.0.1", port), timeout=3)
        try:
            sock.sendall(b"\x05\x01\x00")
            assert receive(sock, 2) == b"\x05\x00"
            destination = b"\xc6\x33\x64\x01\x00\x50" if command == 1 else b"\x00" * 6
            sock.sendall(bytes([5, command, 0, 1]) + destination)
            return sock, reply_address(sock)
        except BaseException:
            sock.close()
            raise

    def traffic(self, port):
        # The destination is TEST-NET, not the echo origin. Only the Shadowsocks
        # server redirects it to loopback, so bypassing encryption cannot pass.
        tcp, _ = self.socks(port, 1)
        with tcp:
            tcp.sendall(b"shadowsocks-tcp")
            assert receive(tcp, 15) == b"shadowsocks-tcp"
        control, relay = self.socks(port, 3)
        with control, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            # UDP can lose a datagram while listeners/sessions start. Retry the
            # same probe on the same association, with a bounded overall wait.
            udp.settimeout(0.5)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                udp.sendto(b"\x00\x00\x00\x01\xc6\x33\x64\x01\x00\x50shadowsocks-udp", relay)
                try:
                    response, _ = udp.recvfrom(4096)
                except socket.timeout:
                    continue
                assert response[:4] == b"\x00\x00\x00\x01" and response[10:] == b"shadowsocks-udp"
                return
            raise AssertionError("Shadowsocks UDP relay did not return the probe")

    def exercise(self, path):
        check = subprocess.run([self.binary, "run", "-test", "-c", str(path)], capture_output=True, timeout=5)
        assert check.returncode == 0, check.stderr.decode()
        config = json.loads(path.read_text())
        proxy = next(o for o in config["outbounds"] if o["protocol"] == "shadowsocks")
        reservations = [socket.socket() for _ in range(3)]
        try:
            for sock in reservations:
                sock.bind(("127.0.0.1", 0))
            server_port, http_port, socks_port = [s.getsockname()[1] for s in reservations]
        finally:
            for sock in reservations:
                sock.close()
        settings = proxy["settings"]
        server = {
            "log": {"loglevel": "warning"},
            "inbounds": [{"listen": "127.0.0.1", "port": server_port, "protocol": "shadowsocks",
                          "settings": {"method": settings["method"], "password": settings["password"], "network": "tcp,udp"}}],
            "outbounds": [{"protocol": "freedom", "settings": {
                "redirect": "127.0.0.1:" + str(self.tcp.getsockname()[1]),
                "finalRules": [{"action": "allow", "ip": ["127.0.0.1/32"]}]}}],
        }
        proxy["settings"]["address"] = "127.0.0.1"
        proxy["settings"]["port"] = server_port
        if path.stem.endswith("tunnel"):
            # Preserve the generated TUN outbound, including sockopt.interface.
            config = {"outbounds": [copy.deepcopy(proxy)], "inbounds": [
                {"protocol": "socks", "listen": "127.0.0.1", "port": socks_port, "settings": {"udp": True}}]}
        else:
            for inbound in config["inbounds"]:
                inbound["port"] = socks_port if inbound["protocol"] == "socks" else http_port
        config["log"] = {"loglevel": "warning"}
        server_process = self.launch("server", server, server_port)
        client = self.launch("client", config, socks_port)
        try:
            self.traffic(socks_port)
            self.stop(client)
            with socket.socket() as stopped:
                assert stopped.connect_ex(("127.0.0.1", socks_port)) != 0, "Client listener survived shutdown"
            client = self.launch("client", config, socks_port)
            self.traffic(socks_port)
            print(path.stem + ": config, TCP, UDP, reconnect passed", flush=True)
        finally:
            self.stop(client)
            self.stop(server_process)

    def close(self):
        for child in reversed(self.children):
            self.stop(child)
        self.tcp.close()
        self.udp.close()
        for log in self.logs:
            log.close()
        assert all(child.poll() is not None for child in self.children), "Xray child survived cleanup"


def interrupted(*_):
    raise RuntimeError("Shadowsocks lab interrupted")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    lab = Lab(sys.argv[1], pathlib.Path(sys.argv[2]))
    try:
        for path in sorted(lab.directory.glob("*-system.json")) + sorted(lab.directory.glob("*-tunnel.json")):
            lab.exercise(path)
    except BaseException:
        for path in lab.directory.glob("*.log"):
            if path.name != "lab.log":
                print(path.name + ":\n" + path.read_text()[-6000:], file=sys.stderr)
        raise
    finally:
        lab.close()
