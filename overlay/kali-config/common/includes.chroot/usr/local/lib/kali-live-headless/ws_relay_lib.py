"""ws_relay_lib — minimal WebSocket-to-TCP relay (rescue channel, v20).

Pure stdlib, no new packages (the wg-enroll precedent): the rescue
channel fronts sshd through a trycloudflare quick tunnel, and quick
tunnels are HTTP(S)-terminated — so SSH rides inside WebSocket binary
frames, end-to-end encrypted by ssh itself; the CDN only sees framed
bytes. This library is the SERVER half that runs on the stick
(cloudflared in front of it); the operator's client half is any
wstunnel-style ws->tcp client.

Server-side WebSocket per RFC 6455 (the inverse of wg_enroll_lib's
client): compute Sec-WebSocket-Accept on handshake, receive MASKED
client frames, send UNMASKED server frames, answer pings, mirror
closes. Data flows as binary (opcode 2) frames in both directions.

Usage (library):
    from ws_relay_lib import serve
    serve(listen_port=8080, target_host="127.0.0.1", target_port=22)

Usage (standalone):
    python3 ws_relay_lib.py --listen 8080 --target 127.0.0.1:22
"""
import argparse
import base64 as b64
import hashlib
import socket
import struct
import sys
import threading

_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG = 0x1, 0x2, 0x8, 0x9, 0xA


def handshake(conn, timeout=15):
    """Read the HTTP upgrade request, reply 101. Returns True on success."""
    conn.settimeout(timeout)
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return False
        data += chunk
        if len(data) > 16384:
            return False
    key = None
    for line in data.split(b"\r\n"):
        if line.lower().startswith(b"sec-websocket-key:"):
            key = line.split(b":", 1)[1].strip()
            break
    if key is None:
        return False
    accept = b64.b64encode(
        hashlib.sha1(key + _WS_GUID.encode()).digest()).decode()
    conn.sendall((
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    return True


def _read_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("ws peer closed mid-frame")
        buf += chunk
    return buf


def recv_frame(conn):
    """Read one complete (defragmented) client message.

    Returns (opcode, payload) of the FINAL logical message; pings are
    answered inline, closes are mirrored and raise ConnectionError.
    Only client->server (masked) frames are expected here.
    """
    opcode_fin, payload = None, b""
    while True:
        hdr = _read_exact(conn, 2)
        fin, op, masked = hdr[0] & 0x80, hdr[0] & 0x0F, hdr[1] & 0x80
        n = hdr[1] & 0x7F
        if n == 126:
            n = struct.unpack(">H", _read_exact(conn, 2))[0]
        elif n == 127:
            n = struct.unpack(">Q", _read_exact(conn, 8))[0]
        if not masked:
            raise ConnectionError("unmasked client frame (RFC 6455 violation)")
        mask = _read_exact(conn, 4)
        body = _read_exact(conn, n) if n else b""
        body = bytes(b ^ mask[i % 4] for i, b in enumerate(body))
        if op == OP_PING:
            send_frame(conn, body, OP_PONG)
            continue
        if op == OP_CLOSE:
            try:
                send_frame(conn, body[:2] if len(body) >= 2 else b"", OP_CLOSE)
            except OSError:
                pass
            raise ConnectionError("ws close")
        if op != 0x0:  # a new message begins
            opcode_fin = op
        payload += body
        if fin:
            return opcode_fin, payload


def send_frame(conn, payload, opcode=OP_BINARY):
    """Send one UNMASKED server frame (3 length forms)."""
    head = bytearray([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head.append(n)
    elif n < 65536:
        head.append(126)
        head += struct.pack(">H", n)
    else:
        head.append(127)
        head += struct.pack(">Q", n)
    conn.sendall(bytes(head) + payload)


def _pump_ws_to_tcp(ws, tcp):
    try:
        while True:
            _, payload = recv_frame(ws)
            if payload:
                tcp.sendall(payload)
    except (ConnectionError, OSError):
        pass
    finally:
        for s in (tcp, ws):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def _pump_tcp_to_ws(tcp, ws):
    try:
        while True:
            data = tcp.recv(65536)
            if not data:
                break
            send_frame(ws, data)
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            send_frame(ws, b"", OP_CLOSE)
        except OSError:
            pass
        for s in (tcp, ws):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def _handle(conn, target_host, target_port):
    try:
        if not handshake(conn):
            return
        tcp = socket.create_connection((target_host, target_port), timeout=10)
        tcp.settimeout(None)
        threads = [threading.Thread(target=_pump_ws_to_tcp, args=(conn, tcp), daemon=True),
                   threading.Thread(target=_pump_tcp_to_ws, args=(tcp, conn), daemon=True)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def serve(listen_port, target_host, target_port, bind="127.0.0.1"):
    """Accept loop: one thread per WebSocket connection.

    Binds loopback by default — the fronting cloudflared proxy is the
    only intended client (nothing else on the stick or the LAN should
    reach this relay).
    """
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((bind, listen_port))
    srv.listen(8)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=_handle, args=(conn, target_host,
                                               target_port), daemon=True).start()


def main(argv=None):
    ap = argparse.ArgumentParser(description="WebSocket<->TCP relay (rescue channel)")
    ap.add_argument("--listen", type=int, required=True, help="ws listen port")
    ap.add_argument("--target", required=True, help="host:port to relay to")
    a = ap.parse_args(argv)
    host, _, port = a.target.rpartition(":")
    serve(a.listen, host or "127.0.0.1", int(port))


if __name__ == "__main__":
    sys.exit(main())
