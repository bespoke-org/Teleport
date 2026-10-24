#!/usr/bin/env python3
"""Loopback-only Hysteria 2 check. Does not install a helper or change routes/proxies."""

import contextlib
import hashlib
import json
from pathlib import Path
import select
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time


class TCPEcho(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        while data := self.request.recv(4096):
            self.request.sendall(b"echo:" + data)


class UDPEcho(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(b"echo:" + data, self.client_address)


def free_port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def receive(sock, count):
    result = b""
    while len(result) < count:
        part = sock.recv(count - len(result))
        if not part:
            raise ConnectionError("Proxy closed the connection")
        result += part
    return result


def socks_request(port, command, target_port):
    sock = socket.create_connection(("127.0.0.1", port), timeout=3)
    try:
        sock.sendall(b"\x05\x01\x00")
        assert receive(sock, 2) == b"\x05\x00"
        sock.sendall(bytes([5, command, 0, 1]) + socket.inet_aton("127.0.0.1") + struct.pack("!H", target_port))
        reply = receive(sock, 4)
        assert reply[:2] == b"\x05\x00", "SOCKS request failed"
        assert reply[3] == 1, "Expected IPv4 loopback SOCKS relay"
        address = socket.inet_ntoa(receive(sock, 4))
        relay_port = struct.unpack("!H", receive(sock, 2))[0]
        return sock, ("127.0.0.1" if address == "0.0.0.0" else address, relay_port)
    except BaseException:
        sock.close()
        raise


def check_tcp(socks_port, echo_port):
    sock, _ = socks_request(socks_port, 1, echo_port)
    with sock:
        sock.sendall(b"hysteria-tcp")
        assert receive(sock, len(b"echo:hysteria-tcp")) == b"echo:hysteria-tcp"


def check_udp(socks_port, echo_port):
    control, relay = socks_request(socks_port, 3, 0)
    with control, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        udp.bind(("127.0.0.1", 0))
        udp.settimeout(3)
        header = b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", echo_port)
        udp.sendto(header + b"hysteria-udp", relay)
        response, _ = udp.recvfrom(4096)
        assert response == header + b"echo:hysteria-udp", "UDP did not round-trip through Hysteria"


def check_http(http_port, echo_port):
    with socket.create_connection(("127.0.0.1", http_port), timeout=3) as sock:
        request = f"CONNECT 127.0.0.1:{echo_port} HTTP/1.1\r\nHost: 127.0.0.1:{echo_port}\r\n\r\n"
        sock.sendall(request.encode())
        headers = b""
        while not headers.endswith(b"\r\n\r\n"):
            headers += receive(sock, 1)
            assert len(headers) < 4096
        assert b" 200 " in headers.split(b"\r\n")[0]
        sock.sendall(b"hysteria-http")
        assert receive(sock, len(b"echo:hysteria-http")) == b"echo:hysteria-http"


def retry(check, seconds=60):
    # Xray 26.10.21 enables Chrome QUIC parroting, which overrides the requested
    # idle timeout. Allow its old session to expire after a server restart.
    deadline = time.monotonic() + seconds
    while True:
        try:
            return check()
        except (OSError, AssertionError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.2)


@contextlib.contextmanager
def running_core(core, config, log):
    with log.open("wb") as output:
        process = subprocess.Popen([str(core), "run", "-c", str(config)], stdout=output, stderr=output)
        try:
            yield process
        except BaseException:
            output.flush()
            print(log.read_text(), file=sys.stderr)
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


class HoppingRelay:
    """Map several public UDP ports to one server, like a provider's port DNAT.

    A single upstream socket preserves the server-side QUIC peer across hops.
    The base port is deliberately blackholed and monitored, never forwarded.
    """

    def __init__(self, server_port, count):
        self.server = ("127.0.0.1", server_port)
        self.sockets = []
        for _ in range(count + 2):
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.bind(("127.0.0.1", 0))
            self.sockets.append(sock)
        self.base, self.upstream, *self.listeners = self.sockets
        self.base_port = self.base.getsockname()[1]
        self.ports = [sock.getsockname()[1] for sock in self.listeners]
        self.events = []
        self.base_packets = 0
        self.failure = None
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.stop.set()
        self.thread.join(timeout=2)
        for sock in self.sockets:
            sock.close()
        assert not self.thread.is_alive(), "Hopping relay did not stop"
        if args[0] is None and self.failure:
            raise self.failure

    def run(self):
        destination = None
        try:
            while not self.stop.is_set():
                ready, _, _ = select.select(self.sockets, [], [], 0.1)
                for sock in ready:
                    data, address = sock.recvfrom(65535)
                    if sock is self.base:
                        self.base_packets += 1
                    elif sock is self.upstream:
                        if destination:
                            listener, client = destination
                            listener.sendto(data, client)
                    else:
                        self.events.append((time.monotonic(), sock.getsockname()[1]))
                        destination = (sock, address)
                        self.upstream.sendto(data, self.server)
        except BaseException as error:
            self.failure = error


def check_hopping(generator, core, root, certificate_pin, tcp_port, udp_port):
    for obfuscation in (None, "Salamander", "Gecko", "Gecko URI"):
        label = obfuscation or "plain TLS"
        masks = []
        if obfuscation:
            settings = {"password": "loopback-obfs-only"}
            if obfuscation == "Gecko":
                settings["packetSize"] = "1200-1400"
            elif obfuscation == "Gecko URI":
                settings["packetSize"] = "512-1200"
            masks.append({"type": "salamander", "settings": settings})
        server_port = free_port(socket.SOCK_DGRAM)
        server_config = root / "hopping-server.json"
        server_config.write_text(json.dumps({
            "log": {"loglevel": "warning"},
            "inbounds": [{
                "listen": "127.0.0.1", "port": server_port, "protocol": "hysteria", "settings": {"version": 2},
                "streamSettings": {
                    "network": "hysteria", "security": "tls",
                    "tlsSettings": {"alpn": ["h3"], "certificates": [{
                        "certificateFile": str(root / "cert.pem"), "keyFile": str(root / "key.pem")
                    }]},
                    "hysteriaSettings": {"version": 2, "auth": "loopback-test-only"},
                    "finalmask": {"udp": masks}
                }
            }],
            "outbounds": [{"protocol": "freedom", "settings": {"finalRules": [{"action": "allow", "ip": ["127.0.0.1"]}]}}]
        }))
        for count in ((1,) if obfuscation == "Gecko URI" else (1, 32)):
            # Isolate server sessions too. Otherwise a previous session can send
            # late datagrams to a closed relay port that the OS has reassigned.
            with running_core(core, server_config, root / "hopping-server.log") as server:
                with HoppingRelay(server_port, count) as relay:
                    ports = ",".join(map(str, relay.ports))
                    final_mask = {"udp": masks + [{
                        "type": "udphop", "settings": {"mode": "intervalremote", "remotePorts": ports, "interval": 5}
                    }]}
                    # Exercise migration from the first installed build as well
                    # as the current core schema. The base port must stay unused.
                    if count == 1 and obfuscation is None:
                        final_mask = {"quicParams": {"udpHop": {"ports": ports, "interval": 5}}}
                    source = root / "hopping-subscription.json"
                    source.write_text(json.dumps([{"outbounds": [{
                        "protocol": "hysteria", "settings": {"version": 2, "address": "127.0.0.1", "port": relay.base_port},
                        "streamSettings": {
                            "network": "hysteria", "security": "tls",
                            "tlsSettings": {"serverName": "localhost", "alpn": ["h3"], "pinnedPeerCertSha256": certificate_pin},
                            "hysteriaSettings": {"version": 2, "auth": "loopback-test-only"}, "finalmask": final_mask
                        }
                    }]}]))
                    if obfuscation == "Gecko URI":
                        # Exercise Gecko's standard URI defaults and the common
                        # mport/alpn/fp extensions through the actual importer.
                        source.write_text(
                            f"hy2://loopback-test-only@127.0.0.1:{relay.base_port}"
                            f"?sni=localhost&pinSHA256={certificate_pin}&mport={ports}"
                            "&obfs=gecko&obfs-password=loopback-obfs-only&alpn=h3&fp=firefox"
                        )
                    socks_port, http_port = free_port(), free_port()
                    client_config = root / "hopping-client.json"
                    subprocess.run([str(generator), "--write-proxy-config", str(source), str(client_config), str(socks_port), str(http_port)], check=True)
                    with running_core(core, client_config, root / "hopping-client.log") as client:
                        try:
                            retry(lambda: check_tcp(socks_port, tcp_port), seconds=4)
                        except (OSError, AssertionError) as error:
                            raise AssertionError(
                                f"{label}: base packets={relay.base_packets}, hopping packets={len(relay.events)}"
                            ) from error
                        check_http(http_port, tcp_port)
                        check_udp(socks_port, udp_port)
                        if count > 1:
                            # The core randomly selects from the advertised ports
                            # and may pick the same one again. Thirty-two choices
                            # and seven intervals make that failure negligible.
                            first_time, first_port = relay.events[0]
                            deadline = first_time + 36
                            continuous, _ = socks_request(socks_port, 1, tcp_port)
                            with continuous:
                                while all(port == first_port for _, port in relay.events):
                                    assert time.monotonic() < deadline, "No interval-based port change observed"
                                    time.sleep(0.2)
                                    continuous.sendall(b"across-hop")
                                    assert receive(continuous, len(b"echo:across-hop")) == b"echo:across-hop"
                                # Keep the same stream alive after the change;
                                # opening a fresh QUIC session cannot satisfy this.
                                continuous.sendall(b"after-hop")
                                assert receive(continuous, len(b"echo:after-hop")) == b"echo:after-hop"
                            changed_at = next(when for when, port in relay.events if port != first_port)
                            assert changed_at - first_time >= 4, f"Port changed after only {changed_at - first_time:.2f} seconds"
                            check_http(http_port, tcp_port)
                            retry(lambda: check_udp(socks_port, udp_port), seconds=8)
                        assert relay.events and relay.base_packets == 0, "Hopping must never send to the base port"
                        assert client.poll() is None and server.poll() is None
                    for port in (socks_port, http_port):
                        with socket.socket() as probe:
                            probe.settimeout(0.2)
                            assert probe.connect_ex(("127.0.0.1", port)) != 0
                    scenario = "sole hopping port" if count == 1 else "interval-based port change"
                    print(f"PASS {label}: {scenario}; TCP, HTTP, UDP; unused base port; cleanup", flush=True)


def main():
    generator = Path(sys.argv[1]).resolve()
    core = Path("teleport/Resources/xray").resolve()
    with tempfile.TemporaryDirectory(prefix="teleport-hysteria-") as temporary, contextlib.ExitStack() as stack:
        root = Path(temporary)
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=localhost", "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem")
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        der = subprocess.check_output(["openssl", "x509", "-in", str(root / "cert.pem"), "-outform", "DER"])
        certificate_pin = hashlib.sha256(der).hexdigest()
        tcp = stack.enter_context(socketserver.ThreadingTCPServer(("127.0.0.1", 0), TCPEcho))
        udp = stack.enter_context(socketserver.ThreadingUDPServer(("127.0.0.1", 0), UDPEcho))
        for server in (tcp, udp):
            threading.Thread(target=server.serve_forever, daemon=True).start()
            stack.callback(server.shutdown)
        for obfuscate in (() if "--hopping-only" in sys.argv else (False, True)):
            label = "Salamander" if obfuscate else "plain TLS"
            server_port = free_port(socket.SOCK_DGRAM)
            socks_port, http_port = free_port(), free_port()
            server_stream = {
                "network": "hysteria", "security": "tls",
                "tlsSettings": {"alpn": ["h3"], "certificates": [{"certificateFile": str(root / "cert.pem"), "keyFile": str(root / "key.pem")}]},
                "hysteriaSettings": {"version": 2, "auth": "loopback-test-only"}
            }
            client_stream = {
                "network": "hysteria", "security": "tls",
                "tlsSettings": {"serverName": "localhost", "alpn": ["h3"], "pinnedPeerCertSha256": certificate_pin, "fingerprint": "firefox"},
                "hysteriaSettings": {"version": 2, "auth": "loopback-test-only"},
                "finalmask": {"quicParams": {"congestion": "bbr", "maxIdleTimeout": 4, "keepAlivePeriod": 2}}
            }
            if obfuscate:
                mask = [{"type": "salamander", "settings": {"password": "loopback-obfs-only"}}]
                server_stream["finalmask"] = {"udp": mask}
                client_stream["finalmask"]["udp"] = mask
            server_config = root / "server.json"
            server_config.write_text(json.dumps({
                "log": {"loglevel": "warning"},
                "inbounds": [{"listen": "127.0.0.1", "port": server_port, "protocol": "hysteria", "settings": {"version": 2}, "streamSettings": server_stream}],
                # Xray blocks loopback targets by default on server inbounds.
                "outbounds": [{"protocol": "freedom", "settings": {"finalRules": [{"action": "allow", "ip": ["127.0.0.1"]}]}}]
            }))
            profile = {"outbounds": [{
                "protocol": "hysteria", "settings": {"version": 2, "address": "127.0.0.1", "port": server_port}, "streamSettings": client_stream
            }]}
            source = root / "subscription.json"
            source.write_text(json.dumps([profile]))
            client_config = root / "client.json"
            subprocess.run([str(generator), "--write-proxy-config", str(source), str(client_config), str(socks_port), str(http_port)], check=True)
            with running_core(core, client_config, root / "client.log") as client:
                for attempt in range(2):
                    # Restart the server while keeping the client alive. Its next
                    # request must recover from the dead QUIC session.
                    with running_core(core, server_config, root / "server.log") as server:
                        retry(lambda: check_tcp(socks_port, tcp.server_address[1]))
                        check_http(http_port, tcp.server_address[1])
                        check_udp(socks_port, udp.server_address[1])
                        assert client.poll() is None and server.poll() is None
                    print(f"PASS {label}: SOCKS TCP, HTTP CONNECT, UDP; server session {attempt + 1}", flush=True)
            # The terminated client must release its listeners.
            for port in (socks_port, http_port):
                with socket.socket() as probe:
                    probe.settimeout(0.2)
                    assert probe.connect_ex(("127.0.0.1", port)) != 0
        check_hopping(generator, core, root, certificate_pin, tcp.server_address[1], udp.server_address[1])
        print("test_hysteria_integration: all checks passed", flush=True)


if __name__ == "__main__":
    main()
