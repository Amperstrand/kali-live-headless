#!/usr/bin/env python3
"""stall-proxy — the watchdog-hang fixture.

Terminates TLS (reusing the testenv's own server cert, trusted by the
guest's baked CA), forwards small responses (the manifest) fully, and
FREEZES mid-body once a response stream passes BYTE_CAP — a 4 MiB chunk
gets ~15 KB in and then nothing, forever, socket held open. bbootd's
body read has no deadline: it hangs without writing /run/bboot/ready or
/run/bboot/failed — the exact condition bb.watchdog-sec exists for.

Usage: stall-proxy.py [listen_port] [byte_cap]
Upstream is always 127.0.0.1:8443 (the standing testenv — read-only
GETs, the traffic it exists to serve). Manifest JSON is far below the
cap; anything bigger (chunks) stalls. The server cert comes from
$SEEDLING_DIR/testenv-m1/pki (the e2e's own PKI).
"""
import os
import socket
import ssl
import sys
import threading
import time

UPSTREAM = ("127.0.0.1", 8443)
SEEDLING_DIR = os.environ.get("SEEDLING_DIR", os.path.expanduser("~/src/seedling-m1"))
PKI = SEEDLING_DIR + "/testenv-m1/pki"
LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8453
BYTE_CAP = int(sys.argv[2]) if len(sys.argv) > 2 else 16384

log = lambda msg: print(f"stall-proxy: {msg}", flush=True)


def relay_requests(cli_tls, up_tls):
    """client -> upstream: relay forever (requests are tiny GETs)."""
    try:
        while True:
            data = cli_tls.read(16384)
            if not data:
                break
            up_tls.write(data)
    except OSError:
        pass


def relay_responses(cli_tls, up_tls):
    """upstream -> client: relay until BYTE_CAP total, then FREEZE."""
    sent = 0
    try:
        while True:
            data = up_tls.read(16384)
            if not data:
                break
            if sent + len(data) > BYTE_CAP:
                head = data[: max(0, BYTE_CAP - sent)]
                if head:
                    cli_tls.write(head)
                log(f"response stream hit the {BYTE_CAP}-byte cap — FREEZING mid-body (the hang fixture)")
                time.sleep(86400)  # hold the socket open: no FIN, no RST
            cli_tls.write(data)
            sent += len(data)
    except OSError:
        pass


def handle(cli):
    try:
        sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        sctx.load_cert_chain(PKI + "/server.crt", PKI + "/server.key")
        cli_tls = sctx.wrap_socket(cli, server_side=True)
        uctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        uctx.check_hostname = False
        uctx.verify_mode = ssl.CERT_NONE
        up_tls = uctx.wrap_socket(socket.create_connection(UPSTREAM, timeout=10),
                                  server_hostname="10.0.2.2")
        threading.Thread(target=relay_requests, args=(cli_tls, up_tls), daemon=True).start()
        relay_responses(cli_tls, up_tls)
    except OSError as e:
        log(f"connection ended: {e}")


def main():
    for f in (PKI + "/server.crt", PKI + "/server.key"):
        if not os.path.isfile(f):
            sys.exit(f"stall-proxy: missing {f} (testenv PKI)")
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", LISTEN_PORT))
    srv.listen(8)
    log(f"listening on 127.0.0.1:{LISTEN_PORT}, upstream {UPSTREAM}, byte cap {BYTE_CAP}")
    while True:
        cli, _ = srv.accept()
        threading.Thread(target=handle, args=(cli,), daemon=True).start()


if __name__ == "__main__":
    main()
