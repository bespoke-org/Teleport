#!/usr/bin/env python3
"""Execute Teleport's generated DNS/routing policies using loopback-only spies.

DNS and routing objects are never rewritten. TUN ingress becomes a loopback DNS
listener; each outbound transport becomes a separate SOCKS5 spy. Spies answer DNS
themselves and never forward traffic. Thus a wrong outbound, private/public
fallback, or resolver-IP collision is observed on actual DNS packets. This does
not exercise real WireGuard/VLESS transports, macOS resolver capture, or PF.
"""
import concurrent.futures
import contextlib
import copy
import hashlib
import json
import os
import pathlib
import shutil
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time
import uuid


def exact(sock, length):
    result = b""
    while len(result) < length:
        chunk = sock.recv(length - len(result))
        if not chunk:
            raise EOFError()
        result += chunk
    return result


def address(read):
    kind = read(1)[0]
    if kind == 1:
        host = socket.inet_ntop(socket.AF_INET, read(4))
    elif kind == 4:
        host = socket.inet_ntop(socket.AF_INET6, read(16))
    elif kind == 3:
        host = read(read(1)[0]).decode("ascii")
    else:
        raise ValueError("Unexpected SOCKS address type")
    return host, struct.unpack("!H", read(2))[0]


def question(packet):
    offset, labels = 12, []
    while packet[offset]:
        length = packet[offset]
        assert length < 64, "Unexpected compressed test question"
        labels.append(packet[offset + 1:offset + length + 1].decode("ascii"))
        offset += length + 1
    offset += 1
    qtype, qclass = struct.unpack("!HH", packet[offset:offset + 4])
    assert qclass == 1
    return ".".join(labels), qtype, packet[12:offset + 4]


class TCPServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 128


class UDPServer(socketserver.ThreadingUDPServer):
    daemon_threads = True
    allow_reuse_address = True


class Spy:
    def __init__(self, tag, lab):
        self.tag, self.lab = tag, lab
        self.number = {"proxy": 10, "proxy-1": 11, "proxy-2": 12, "direct": 13}[tag]
        spy = self

        class UDP(socketserver.BaseRequestHandler):
            def handle(self):
                packet, sock = self.request
                assert packet[:3] == b"\0\0\0", "Fragmented SOCKS UDP is unsupported in this lab"
                cursor = 3

                def read(length):
                    nonlocal cursor
                    data = packet[cursor:cursor + length]
                    cursor += length
                    return data

                host, port = address(read)
                reply = spy.answer(host, port, packet[cursor:], "udp")
                if reply is not None:
                    sock.sendto(packet[:cursor] + reply, self.client_address)

        class TCP(socketserver.BaseRequestHandler):
            def handle(self):
                try:
                    self.request.settimeout(10)
                    version, count = exact(self.request, 2)
                    assert version == 5 and 0 in exact(self.request, count)
                    self.request.sendall(b"\x05\x00")
                    version, command, reserved = exact(self.request, 3)
                    assert version == 5 and reserved == 0
                    host, port = address(lambda n: exact(self.request, n))
                    if command == 3:
                        self.request.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01" + struct.pack("!H", spy.udp.server_address[1]))
                        while self.request.recv(1):
                            pass
                        return
                    assert command == 1
                    self.request.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
                    if port == 443:
                        # The production DoH URL reaches this transport unchanged.
                        # Reject the TLS handshake; no external connection is made.
                        first = exact(self.request, 1)
                        lab.record({"tag": spy.tag, "host": host, "port": port, "tls": first.hex()})
                        return
                    while True:
                        length = struct.unpack("!H", exact(self.request, 2))[0]
                        reply = spy.answer(host, port, exact(self.request, length), "tcp")
                        if reply is not None:
                            self.request.sendall(struct.pack("!H", len(reply)) + reply)
                except (EOFError, ConnectionError, socket.timeout):
                    pass
                except Exception as error:
                    lab.record({"error": repr(error), "tag": spy.tag})

        self.udp = UDPServer(("127.0.0.1", 0), UDP)
        self.tcp = TCPServer(("127.0.0.1", 0), TCP)
        for server in (self.udp, self.tcp):
            threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()

    def answer(self, host, port, packet, transport):
        name, qtype, raw_question = question(packet)
        self.lab.record({"tag": self.tag, "host": host, "port": port, "name": name,
                         "qtype": qtype, "transport": transport})
        assert host in ("1.1.1.1", "1.0.0.1") and port == 53
        mode = name.split("-", 1)[0]
        if mode == "timeout":
            return None
        if mode == "failfirst":
            mode = "servfail" if host == "1.1.1.1" else "ok"
        rcode = {"nxdomain": 3, "servfail": 2}.get(mode, 0)
        answer = b""
        if mode == "ok":
            packed = socket.inet_pton(socket.AF_INET, f"203.0.113.{self.number}") if qtype == 1 else \
                socket.inet_pton(socket.AF_INET6, f"2001:db8::{self.number}")
            answer = b"\xc0\x0c" + struct.pack("!HHIH", qtype, 1, 0, len(packed)) + packed
        return packet[:2] + struct.pack("!HHHHH", 0x8180 | rcode, 1, bool(answer), 0, 0) + raw_question + answer

    def close(self):
        for server in (self.tcp, self.udp):
            server.shutdown()
            server.server_close()


class Lab:
    def __init__(self, binary, directory, name, generated):
        self.binary, self.directory, self.name = binary, directory, name
        self.generated = generated
        self.events, self.results, self.spies = [], [], []
        self.lock = threading.Lock()
        self.child = self.log = None

    def record(self, event):
        with self.lock:
            self.events.append(event)

    def start(self):
        config = copy.deepcopy(self.generated)
        with contextlib.closing(socket.socket()) as reservation:
            reservation.bind(("127.0.0.1", 0))
            self.port = reservation.getsockname()[1]
        config["inbounds"] = [{"tag": "tun", "listen": "127.0.0.1", "port": self.port,
            "protocol": "dokodemo-door", "settings": {"network": "tcp,udp", "address": "1.1.1.1", "port": 53}}]
        for index, outbound in enumerate(config["outbounds"]):
            if outbound["protocol"] in ("dns", "blackhole"):
                continue
            spy = Spy(outbound["tag"], self)
            self.spies.append(spy)
            config["outbounds"][index] = {"tag": spy.tag, "protocol": "socks",
                "settings": {"servers": [{"address": "127.0.0.1", "port": spy.tcp.server_address[1]}]}}
        assert config["dns"] == self.generated["dns"]
        assert config["routing"] == self.generated["routing"]
        config["log"] = {"loglevel": "warning"}
        config_path = self.directory / (self.name + ".json")
        config_path.write_text(json.dumps(config))
        self.log = open(self.directory / (self.name + ".log"), "wb")
        self.child = subprocess.Popen([self.binary, "run", "-c", str(config_path)], stdout=self.log, stderr=self.log)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            assert self.child.poll() is None, "Fixture Xray exited before listening"
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.1):
                    return
            except OSError:
                time.sleep(0.03)
        raise AssertionError("Fixture Xray did not listen")

    def query(self, zone, mode, qtype, expected_tag, tcp=False):
        name = f"{mode}-{uuid.uuid4().hex}.{zone}"
        ident = os.urandom(2)
        packet = ident + struct.pack("!HHHHH", 0x0100, 1, 0, 0, 0)
        packet += b"".join(bytes([len(label)]) + label.encode() for label in name.split("."))
        packet += b"\0" + struct.pack("!HH", qtype, 1)
        with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM)) as sock:
            sock.settimeout(6)
            sock.connect(("127.0.0.1", self.port))
            sock.sendall(struct.pack("!H", len(packet)) + packet if tcp else packet)
            try:
                reply = exact(sock, struct.unpack("!H", exact(sock, 2))[0]) if tcp else sock.recv(4096)
            except socket.timeout:
                reply = None
        if reply:
            assert reply[:2] == ident and len(reply) >= 12
        time.sleep(0.05)
        with self.lock:
            events = [e for e in self.events if e.get("name") == name]
        assert events, f"{self.name}: no upstream saw {name}"
        assert {e["tag"] for e in events} == {expected_tag}, f"DNS leak/wrong outbound: {name}: {events}"
        answered = reply is not None and struct.unpack("!H", reply[6:8])[0] > 0
        if mode in ("ok", "failfirst"):
            assert answered, f"{name}: expected an answer from {expected_tag}"
            number = next(s.number for s in self.spies if s.tag == expected_tag)
            packed = socket.inet_pton(socket.AF_INET, f"203.0.113.{number}") if qtype == 1 else \
                socket.inet_pton(socket.AF_INET6, f"2001:db8::{number}")
            assert packed in reply, f"{name}: wrong resolver answer"
        else:
            assert not answered, f"{name}: failure unexpectedly resolved through fallback"
        if mode == "failfirst":
            assert {e["host"] for e in events} == {"1.1.1.1", "1.0.0.1"}, events
        result = {"zone": zone, "mode": mode, "qtype": qtype, "ingress": "tcp" if tcp else "udp",
                  "outbound": expected_tag, "queries": len(events), "answered": answered}
        with self.lock:
            self.results.append(result)

    def run(self):
        self.start()
        if self.name == "doh-failure":
            # No plaintext query may reach any spy when public DoH cannot connect,
            # even though local and peer resolvers use the same IP as the DoH URL.
            with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_DGRAM)) as sock:
                sock.settimeout(6)
                name = "doh-failure.public.test"
                question_bytes = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0\0\x01\0\x01"
                sock.sendto(b"\x12\x34\x01\x00\x00\x01" + b"\0" * 6 + question_bytes, ("127.0.0.1", self.port))
                try:
                    reply = sock.recv(4096)
                    assert struct.unpack("!H", reply[6:8])[0] == 0
                except socket.timeout:
                    pass
            assert self.events and all(e.get("tls") == "16" and e["tag"] == "proxy" and
                e["host"] == "1.1.1.1" and e["port"] == 443 for e in self.events), self.events
            self.results.append({"mode": "production DoH TLS failure", "outbound": "proxy", "plaintext_queries": 0})
        else:
            zones = [("public.test", "proxy"), ("direct.test", "proxy"),
                     ("home.arpa", "direct"), ("first.test", "proxy-1"),
                     ("second.test", "proxy-2"), ("overlap.test", "proxy-2")]
            if self.name == "full-proxy":
                zones = [("public.test", "proxy"), ("home.arpa", "proxy")]
            if self.name == "default-peer":
                zones = [("public.test", "proxy")]
            jobs = [(zone, mode, qtype, tag, qtype == 28) for zone, tag in zones
                    for mode in ("ok", "nxdomain", "empty", "servfail", "timeout") for qtype in (1, 28)]
            if self.name == "default-peer":
                jobs += [("public.test", "failfirst", qtype, "proxy", False) for qtype in (1, 28)]
            with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
                futures = [pool.submit(self.query, *job) for job in jobs]
                for future in futures:
                    future.result()
        assert not any("error" in e for e in self.events), self.events
        print(f"{self.name}: {len(self.results)} DNS cases passed; no cross-group queries", flush=True)

    def close(self):
        if self.child is not None and self.child.poll() is None:
            self.child.terminate()
            try:
                self.child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait(timeout=3)
        for spy in self.spies:
            spy.close()
        if self.log is not None:
            self.log.close()


def interrupted(*_):
    raise RuntimeError("DNS integration test interrupted")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    binary, source = sys.argv[1:]
    source = pathlib.Path(source)
    results, controls = [], []
    fixtures = json.loads(source.read_text())
    try:
        for name, generated in fixtures.items():
            lab = Lab(binary, source.parent, name, generated)
            try:
                lab.run()
                results.append({"fixture": name, "cases": lab.results, "events": lab.events})
            finally:
                lab.close()
        # Prove that the detector rejects leaks, rather than only observing
        # failures. These intentionally unsafe policies never leave loopback.
        for control in ("wrong-outbound", "cross-group-fallback"):
            generated = copy.deepcopy(fixtures["udp"])
            if control == "wrong-outbound":
                rule = next(r for r in generated["routing"]["rules"] if r.get("inboundTag") == ["dns-internal"])
                rule["outboundTag"] = "direct"
                query = ("public.test", "ok", 1, "proxy")
            else:
                generated["dns"]["servers"][0]["finalQuery"] = False
                query = ("home.arpa", "servfail", 1, "direct")
            lab = Lab(binary, source.parent, control, generated)
            try:
                lab.start()
                try:
                    lab.query(*query)
                except AssertionError as error:
                    assert str(error).startswith("DNS leak/wrong outbound:"), str(error)
                    controls.append({"control": control, "detected": True, "events": lab.events})
                    print(f"Negative control detected: {control}", flush=True)
                else:
                    raise AssertionError(f"Detector missed negative control: {control}")
            finally:
                lab.close()
        report = {"xray_sha256": hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest(),
                  "generated_config_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                  "results": results, "negative_controls": controls}
        (source.parent / "report.json").write_text(json.dumps(report, indent=2))
        print(f"PASS: {sum(len(r['cases']) for r in results)} runtime DNS cases; all Xray children stopped", flush=True)
    except Exception:
        for log in source.parent.glob("*.log"):
            if log.name != "lab.log":
                print(f"{log.name}:\n{log.read_text()[-4000:]}", file=sys.stderr)
        raise
    finally:
        if os.environ.get("TELEPORT_DNS_LAB_OUTPUT"):
            shutil.copytree(source.parent, os.environ["TELEPORT_DNS_LAB_OUTPUT"], dirs_exist_ok=True)
