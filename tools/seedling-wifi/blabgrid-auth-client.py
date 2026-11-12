#!/usr/bin/env python3
"""blabgrid-auth-client — local proxy that authenticates to blabgrid-auth.

labgrid-client speaks plain TCP to its coordinator, so authenticated
access needs a shim: this proxy listens on a LOCAL port, performs the
Nostr challenge-response against the remote blabgrid-auth proxy (BIP-340
signature over the challenge with your nsec), and then splices bytes
both ways. Point labgrid-client at the local port:

    blabgrid-auth-client --remote 192.0.2.9:20409 --listen 127.0.0.1:20410 \
                         --nsec-file ~/.labgrid/my-key &
    labgrid-client -c 127.0.0.1:20410 places

Identity: the nsec (or BBOOT_NSEC env). The npub sent in the handshake
is derived from it — you cannot claim to be anyone else without their
key (that was not true of the initial SHA256 scheme).
"""
import argparse
import os
import socket
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from schnorr import nsec_bytes, npub_of, sign


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--remote", required=True, help="blabgrid-auth host:port")
    ap.add_argument("--listen", default="127.0.0.1:20410")
    ap.add_argument("--nsec-file")
    args = ap.parse_args()

    nsec = os.environ.get("BBOOT_NSEC", "")
    if args.nsec_file:
        nsec = open(args.nsec_file).read().strip()
    if not nsec:
        sys.exit("blabgrid-auth-client: set BBOOT_NSEC or --nsec-file")
    sk = nsec_bytes(nsec)
    npub = npub_of(sk)

    rhost, rport = args.remote.split(":")
    lhost, lport = args.listen.split(":")

    def splice(a, b):
        try:
            while True:
                data = a.recv(65536)
                if not data:
                    break
                b.sendall(data)
        except OSError:
            pass
        finally:
            try:
                a.close()
                b.close()
            except OSError:
                pass

    def handle(client):
        remote = socket.create_connection((rhost, int(rport)), timeout=10)
        # 1. read the challenge line
        line = b""
        while not line.endswith(b"\n"):
            chunk = remote.recv(4096)
            if not chunk:
                client.close()
                remote.close()
                return
            line += chunk
        challenge_hex = line.decode().strip().split()[-1]
        # 2. sign it (BIP-340 over the raw challenge bytes) and identify
        sig = sign(bytes.fromhex(challenge_hex), sk)
        remote.sendall(f"auth {npub} {sig.hex()}\n".encode())
        # 3. splice everything (the coordinator protocol is symmetric)
        t = threading.Thread(target=splice, args=(client, remote), daemon=True)
        t.start()
        splice(remote, client)

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((lhost, int(lport)))
    srv.listen(8)
    print(f"blabgrid-auth-client: {lhost}:{lport} -> {args.remote} as {npub[:20]}…", flush=True)
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
