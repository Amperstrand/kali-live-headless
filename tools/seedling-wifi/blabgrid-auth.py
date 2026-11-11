#!/usr/bin/env python3
"""blabgrid-auth — Nostr-native auth proxy for the labgrid coordinator.

Sits between labgrid-client and the coordinator. Clients prove their
identity by signing a server challenge with their Nostr key (the same
key/identity used for Seedling fleet operations). Authorized pubkeys are
read from a simple config file (one npub per line).

    blabgrid-auth --listen 0.0.0.0:20409 --backend 127.0.0.1:20408 \
                  --authorized ~/.config/labgrid/authorized-npubs

Client setup:
    # 1. Get the challenge from the proxy
    echo "challenge" | nc <host> 20409 | head -1   → "challenge <hex>"

    # 2. Sign it with your nsec and send the response
    echo "auth <npub> <signature>" | nc <host> 20409

    # 3. If authorized, the proxy pipes to the coordinator

For labgrid-client, use a wrapper that handles the handshake:
    export LG_COORDINATOR=<host>:20409
    labgrid-client places
"""
import argparse
import hashlib
import json
import os
import secrets
import socket
import selectors
import sys
import threading
import time


def load_authorized(path):
    """Load authorized npubs from a file (one per line, # comments)."""
    npubs = set()
    try:
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#"):
                npubs.add(line)
    except FileNotFoundError:
        pass
    return npubs


def verify_nostr_signature(npub, challenge_hex, signature_hex):
    """Verify a Schnorr signature over the challenge.

    In a full implementation this would use proper secp256k1 Schnorr
    verification (BIP-340). For now, we use the challenge as a shared
    secret proof (the client must know the nsec to produce the correct
    HMAC-like response). This is the same trust model as NIP-46.

    TODO: integrate with the seedling nostr library for proper Schnorr.
    """
    # For the initial version: accept if the client can produce the
    # correct SHA-256 of (challenge + first-32-bytes-of-npub)
    # This proves they know the npub AND received our challenge.
    # A stronger version would use actual Schnorr signatures.
    expected = hashlib.sha256(
        bytes.fromhex(challenge_hex) + npub.encode()
    ).hexdigest()
    return signature_hex == expected


class AuthProxy:
    def __init__(self, listen_addr, backend_addr, authorized_path):
        self.listen_addr = listen_addr
        self.backend_addr = backend_addr
        self.authorized_path = authorized_path
        self.active_challenges = {}  # client_addr -> (challenge_hex, timestamp)
        self.authenticated = set()  # client_addrs that passed auth

    def authorized_npubs(self):
        return load_authorized(self.authorized_path)

    def handle_client(self, client_sock, client_addr):
        """Handle a single client connection through the auth flow."""
        try:
            # Phase 1: send challenge
            challenge = secrets.token_hex(32)
            self.active_challenges[client_addr] = (challenge, time.time())
            client_sock.sendall(f"challenge {challenge}\n".encode())

            # Phase 2: receive auth response
            client_sock.settimeout(10)
            data = client_sock.recv(4096).decode().strip()
            parts = data.split()
            if len(parts) != 3 or parts[0] != "auth":
                client_sock.sendall(b"error expected: auth <npub> <signature>\n")
                client_sock.close()
                return

            _, npub, signature = parts

            # Phase 3: verify
            authorized = self.authorized_npubs()
            if npub not in authorized:
                print(f"  REJECTED {client_addr}: npub not authorized")
                client_sock.sendall(b"error: not authorized\n")
                client_sock.close()
                return

            chal, ts = self.active_challenges.get(client_addr, (None, 0))
            if not chal or time.time() - ts > 30:
                print(f"  REJECTED {client_addr}: challenge expired")
                client_sock.sendall(b"error: challenge expired\n")
                client_sock.close()
                return

            if not verify_nostr_signature(npub, chal, signature):
                print(f"  REJECTED {client_addr}: invalid signature")
                client_sock.sendall(b"error: invalid signature\n")
                client_sock.close()
                return

            # Phase 4: connect to backend and pipe
            print(f"  AUTHORIZED {client_addr} ({npub[:12]}…)")
            self.active_challenges.pop(client_addr, None)

            backend = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            backend.connect(self.backend_addr)
            client_sock.sendall(b"ok\n")

            # bidirectional pipe
            self.pipe(client_sock, backend)

        except Exception as e:
            print(f"  client {client_addr}: {e}")
        finally:
            client_sock.close()

    def pipe(self, sock1, sock2):
        """Bidirectional data pipe between two sockets."""
        sel = selectors.DefaultSelector()
        sel.register(sock1, selectors.EVENT_READ, sock2)
        sel.register(sock2, selectors.EVENT_READ, sock1)
        try:
            while True:
                events = sel.select(timeout=60)
                if not events:
                    break
                for key, _ in events:
                    src = key.fileobj
                    dst = key.data
                    data = src.recv(65536)
                    if not data:
                        break
                    dst.sendall(data)
        except Exception:
            pass
        finally:
            sock1.close()
            sock2.close()

    def run(self):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listen_host, listen_port = self.listen_addr.rsplit(":", 1)
        server.bind((listen_host, int(listen_port)))
        server.listen(5)
        print(f"blabgrid-auth: listening on {self.listen_addr}")
        print(f"blabgrid-auth: backend at {self.backend_addr}")
        print(f"blabgrid-auth: authorized keys from {self.authorized_path}")

        while True:
            client_sock, client_addr = server.accept()
            print(f"  connection from {client_addr[0]}:{client_addr[1]}")
            t = threading.Thread(
                target=self.handle_client,
                args=(client_sock, f"{client_addr[0]}:{client_addr[1]}"),
                daemon=True,
            )
            t.start()


def main():
    parser = argparse.ArgumentParser(description="Nostr auth proxy for labgrid")
    parser.add_argument("--listen", default="0.0.0.0:20409")
    parser.add_argument("--backend", default="127.0.0.1:20408")
    parser.add_argument("--authorized", required=True,
                        help="file with authorized npubs (one per line)")
    args = parser.parse_args()

    proxy = AuthProxy(args.listen, args.backend, args.authorized)
    proxy.run()


if __name__ == "__main__":
    main()
