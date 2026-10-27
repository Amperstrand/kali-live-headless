#!/usr/bin/env python3
"""List removable/USB whole disks with their serials and by-id paths."""

from __future__ import annotations

import json
import os
import subprocess
import sys

LSBLK = [
    "lsblk",
    "-J",
    "-o",
    "NAME,PATH,TYPE,TRAN,RM,SIZE,MODEL,SERIAL,MOUNTPOINTS",
]


def by_id(device: str) -> list[str]:
    result: list[str] = []
    directory = "/dev/disk/by-id"
    try:
        entries = os.listdir(directory)
    except OSError:
        return result
    for name in entries:
        if not name.startswith("usb-"):
            continue
        path = os.path.join(directory, name)
        try:
            if os.path.realpath(path) == device:
                result.append(name)
        except OSError:
            continue
    return sorted(result)


def main() -> int:
    data = json.loads(subprocess.check_output(LSBLK, text=True))
    rows = []
    for disk in data.get("blockdevices", []):
        transport = (disk.get("tran") or "").lower()
        removable = disk.get("rm") in (True, 1, "1", "true")
        if disk.get("type") != "disk" or not (transport == "usb" or removable):
            continue

        mounts = []
        for node in [disk, *disk.get("children", [])]:
            for mount in node.get("mountpoints") or []:
                if mount:
                    mounts.append(mount)

        rows.append(
            (
                disk.get("path", ""),
                disk.get("size", ""),
                (disk.get("model") or "").strip(),
                (disk.get("serial") or "").strip(),
                ",".join(mounts) or "-",
                ", ".join(by_id(disk.get("path", ""))) or "-",
            )
        )

    if not rows:
        print("No removable USB disks found.")
        return 0

    print(
        f"{'DEVICE':12} {'SIZE':8} {'MODEL':32} {'SERIAL':22} {'MOUNTS':24} BY-ID"
    )
    for device, size, model, serial, mounts, ids in rows:
        print(
            f"{device:12} {size:8} {model[:32]:32} {serial[:22]:22} "
            f"{mounts[:24]:24} {ids}"
        )
        if size.endswith("T") and size[:-1].replace(".", "").isdigit():
            print("  note: large USB disk; the Ventoy role refuses >2 TB by default")
    return 0


if __name__ == "__main__":
    sys.exit(main())
