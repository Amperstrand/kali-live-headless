#!/usr/bin/env python3
"""blabgrid-exporter — dynamic labgrid exporter driven by Nostr births.

Runs on the workstation alongside the coordinator. Watches the Nostr
relay for Seedling birth events and dynamically generates a labgrid
exporter configuration that exposes each machine as a NetworkService
(SSH) resource. No rootfs changes needed — the exporter runs centrally.

    blabgrid-exporter --relay wss://host:port --ca ca.pem

The exporter config is written to /tmp/labgrid-exporter.yaml and the
labgrid-exporter process is managed as a child. When machines birth
or disappear, the config is regenerated and the exporter reloads.
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

# reuse the relay listener from blabgrid.py
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from blabgrid import ws_connect, ws_send, ws_recv, event_id_ok

EXPORTER_CONFIG = None  # path to the YAML config


def generate_exporter_yaml(machines):
    """Generate a labgrid exporter YAML config from the machine list."""
    lines = []
    for name, info in machines.items():
        lines.append(f"{name}:")
        lines.append(f"  NetworkService:")
        lines.append(f"    address: {info['ip']}")
        lines.append(f"    username: root")
        lines.append(f"    port: 22")
        lines.append("")
    return "\n".join(lines)


def write_config(machines, path):
    yaml = generate_exporter_yaml(machines)
    with open(path, "w") as f:
        f.write(yaml)
    print(f"  exporter config updated: {len(machines)} machine(s)")


def restart_exporter(config_path, coordinator, exporter_bin):
    """Restart the labgrid-exporter with the new config."""
    subprocess.run(["pkill", "-f", "labgrid-exporter"], capture_output=True)
    time.sleep(1)
    # labgrid-exporter takes the config as a positional arg, -c for coordinator
    proc = subprocess.Popen(
        [exporter_bin, "-c", coordinator, config_path],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return proc


def main():
    parser = argparse.ArgumentParser(description="Dynamic labgrid exporter from Nostr births")
    parser.add_argument("--relay", required=True)
    parser.add_argument("--ca", help="TLS CA file")
    parser.add_argument("--coordinator", default="127.0.0.1:20408")
    parser.add_argument("--exporter-bin", default="labgrid-exporter")
    parser.add_argument("--config-dir", default="/tmp")
    args = parser.parse_args()

    config_path = os.path.join(args.config_dir, "labgrid-exporter.yaml")
    machines = {}
    exporter_proc = None
    last_config_hash = ""

    print(f"blabgrid-exporter: watching {args.relay}")
    print(f"blabgrid-exporter: coordinator at {args.coordinator}")
    print(f"blabgrid-exporter: config at {config_path}")

    while True:
        try:
            sock = ws_connect(args.relay, args.ca)
            sub = json.dumps(["REQ", "blabgrid-exporter", {"kinds": [30078], "limit": 50}])
            ws_send(sock, sub)
            sock.settimeout(5)
            config_dirty = False

            while True:
                try:
                    msg = ws_recv(sock)
                except (socket_error, TimeoutError):
                    # periodic config sync check
                    continue
                except EOFError:
                    break

                m = json.loads(msg)
                if m[0] != "EVENT":
                    continue
                ev = m[2]
                if not event_id_ok(ev):
                    continue

                tags = {t[0]: t[1] for t in ev.get("tags", []) if len(t) == 2}
                if tags.get("d") != "birth":
                    continue

                try:
                    content = json.loads(ev["content"])
                except json.JSONDecodeError:
                    continue

                serial = content.get("serial", tags.get("machine", ""))
                hostname = content.get("hostname", serial[:12])
                ips = content.get("ips", [])
                if not serial or not ips:
                    continue

                ip = ips[0]
                if machines.get(hostname, {}).get("ip") != ip:
                    machines[hostname] = {"ip": ip, "serial": serial}
                    config_dirty = True
                    print(f"  machine: {hostname} at {ip}")

                # write config if changed
                if config_dirty:
                    write_config(machines, config_path)
                    new_hash = str(hash(json.dumps(machines, sort_keys=True)))
                    if new_hash != last_config_hash:
                        last_config_hash = new_hash
                        if exporter_proc:
                            exporter_proc.terminate()
                            exporter_proc.wait()
                        exporter_proc = restart_exporter(
                            config_path, args.coordinator, args.exporter_bin
                        )
                        config_dirty = False

        except KeyboardInterrupt:
            if exporter_proc:
                exporter_proc.terminate()
            break
        except Exception as e:
            print(f"blabgrid-exporter: {e}, retrying in 5s...")
            time.sleep(5)


if __name__ == "__main__":
    import socket as socket_error
    main()
