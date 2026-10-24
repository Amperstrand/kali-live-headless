"""Container tests for ws_relay_lib (rescue channel, v20).

The client half is a minimal stdlib WebSocket client (masked frames —
the RFC 6455 inverse of the relay under test). Covers the handshake,
both pump directions, all three frame-length forms, ping/pong, close
handling, concurrency, and target-refused behaviour.
"""
import base64 as b64
import hashlib
import os
import socket
import struct
import sys
import threading
import time
import unittest

sys.path.insert(0, os.environ.get(
    "KLH_REPO", "/repo") + "/overlay/kali-config/common/includes.chroot/"
    "usr/local/lib/kali-live-headless")
import ws_relay_lib as R  # noqa: E402

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class WSClient:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        key = b64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            f"GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n").encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += self.sock.recv(4096)
        assert b" 101 " in resp.split(b"\r\n", 1)[0], resp[:120]
        want = b64.b64encode(hashlib.sha1(key.encode() + GUID.encode()).digest())
        assert want in resp, "bad Sec-WebSocket-Accept"

    def _read(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("eof")
            buf += chunk
        return buf

    def send(self, payload, opcode=2):
        mask = os.urandom(4)
        head = bytearray([0x80 | opcode])
        n = len(payload)
        if n < 126:
            head.append(0x80 | n)
        elif n < 65536:
            head.append(0x80 | 126); head += struct.pack(">H", n)
        else:
            head.append(0x80 | 127); head += struct.pack(">Q", n)
        head += mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(head))

    def recv(self):
        while True:
            hdr = self._read(2)
            op = hdr[0] & 0x0F
            n = hdr[1] & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            payload = self._read(n) if n else b""
            if op == 0x9:          # ping from server -> pong back, keep reading
                self.send(payload, 0xA)
                continue
            return op, payload

    def close(self):
        try:
            self.send(struct.pack(">H", 1000), 8)
        except OSError:
            pass
        self.sock.close()


def tcp_server(handler):
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0)); srv.listen(8)

    def loop():
        while True:
            try:
                c, _ = srv.accept()
            except OSError:
                return
            threading.Thread(target=handler, args=(c,), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()
    return srv.getsockname()[1]


def free_port():
    # bind(0), read the port, CLOSE the socket — a lingering listener here
    # made serve()'s bind fail with EADDRINUSE and killed the relay thread
    # (the first container run hung on exactly that).
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def start_relay(target_port):
    relay_port = free_port()
    t = threading.Thread(target=R.serve, args=(relay_port, "127.0.0.1",
                                               target_port), daemon=True)
    t.start()
    time.sleep(0.2)
    return relay_port


class TestRelay(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        def echo(c):
            with c:
                while True:
                    d = c.recv(65536)
                    if not d:
                        return
                    c.sendall(d)
        cls.echo_port = tcp_server(echo)
        cls.relay_port = start_relay(cls.echo_port)

    def rx_exact(self, ws, n):
        buf = b""
        while len(buf) < n:
            _, p = ws.recv()
            buf += p
        return buf

    def test_roundtrip_all_length_forms(self):
        ws = WSClient(self.relay_port)
        for size in (1, 125, 126, 127, 65535, 65536, 70000):
            payload = os.urandom(size)
            ws.send(payload)
            got = self.rx_exact(ws, size)
            self.assertEqual(got, payload, f"size {size}")
        ws.close()

    def test_server_push(self):
        banner = b"SSH-2.0-rescue-test\r\n"
        def greet(c):
            with c:
                c.sendall(banner)
                while c.recv(4096):
                    pass
        port = tcp_server(greet)
        relay = start_relay(port)
        ws = WSClient(relay)
        op, p = ws.recv()
        self.assertEqual(p, banner)
        ws.close()

    def test_ping_pong(self):
        ws = WSClient(self.relay_port)
        ws.send(b"ping-payload", 0x9)
        # echo target never sees it; we must get a pong back on next recv
        op, p = ws.recv()
        self.assertEqual(op, 0xA)
        self.assertEqual(p, b"ping-payload")
        ws.close()

    def test_two_concurrent_connections(self):
        a, b = WSClient(self.relay_port), WSClient(self.relay_port)
        pa, pb = os.urandom(5000), os.urandom(5000)
        a.send(pa); b.send(pb)
        self.assertEqual(self.rx_exact(a, len(pa)), pa)
        self.assertEqual(self.rx_exact(b, len(pb)), pb)
        a.close(); b.close()

    def test_target_refused_closes_cleanly(self):
        relay = start_relay(1)  # tcp/1 on loopback: refused
        ws = WSClient(relay)
        try:
            ws.send(b"x")
        except OSError:
            pass  # relay already closed us - equally fine
        with self.assertRaises((ConnectionError, OSError)):
            ws.recv()
        ws.close()

    def test_close_mirror(self):
        ws = WSClient(self.relay_port)
        ws.send(b"", 0x8)
        op, _ = ws.recv()
        self.assertEqual(op, 0x8)


if __name__ == "__main__":
    unittest.main()
