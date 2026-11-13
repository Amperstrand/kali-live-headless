#!/usr/bin/env python3
"""fat-normalize.py — pin every FAT16/FAT32 directory-entry timestamp to a
fixed epoch, making an mtools-built FAT byte-reproducible.

mtools stamps creation times from the wall clock, and faketime does not
intercept its clock source (found by double-build cmp on the Pi SD image).
This parses the BPB, locates the root directory (fixed region on FAT16,
cluster chain on FAT32), walks subdirectory chains, and rewrites
CrtTimeTenth/CrtTime/CrtDate/LstAccDate/WrtTime/WrtDate on every valid
entry (skipping LFN slots, deleted and free entries). It never writes
outside directory clusters.

Usage: fat-normalize.py IMAGE [EPOCH]
"""
import struct
import sys
import datetime


def fat_times(epoch: int):
    dt = datetime.datetime.fromtimestamp(epoch, tz=datetime.timezone.utc)
    year = max(dt.year, 1980)
    date = ((year - 1980) << 9) | (dt.month << 5) | dt.day
    time = (dt.hour << 11) | (dt.minute << 5) | (dt.second // 2)
    return time, date


class Fat:
    def __init__(self, img: bytes):
        self.img = img
        b = img
        self.bps = struct.unpack_from("<H", b, 11)[0]
        self.spc = b[13]
        self.rsvd = struct.unpack_from("<H", b, 14)[0]
        self.nfats = b[16]
        root_cnt = struct.unpack_from("<H", b, 17)[0]
        fat16 = struct.unpack_from("<H", b, 22)[0]
        self.is32 = root_cnt == 0 or fat16 == 0
        fat32 = struct.unpack_from("<I", b, 36)[0]
        self.fat_sz = fat32 if self.is32 else fat16
        self.root_cluster = struct.unpack_from("<I", b, 44)[0] if self.is32 else 0
        self.fat_off = self.rsvd * self.bps
        self.root_off = self.fat_off + self.nfats * self.fat_sz * self.bps
        self.root_bytes = root_cnt * 32
        self.data_off = self.root_off + (self.root_bytes if not self.is32 else 0)
        self.clus_bytes = self.spc * self.bps
        if self.is32:
            self.eoc = 0x0FFFFFF8
            self.fat_ent = self._fat32
        else:
            self.eoc = 0xFFF8
            self.fat_ent = self._fat16

    def _fat16(self, c: int) -> int:
        return struct.unpack_from("<H", self.img, self.fat_off + 2 * c)[0]

    def _fat32(self, c: int) -> int:
        return struct.unpack_from("<I", self.img, self.fat_off + 4 * c)[0] & 0x0FFFFFFF

    def cluster_off(self, c: int) -> int:
        return self.data_off + (c - 2) * self.clus_bytes


def normalize(path: str, epoch: int) -> int:
    with open(path, "r+b") as f:
        img = bytearray(f.read())
        fs = Fat(bytes(img))
        t, d = fat_times(epoch)
        fixed = 0

        def fix_entry(off: int) -> int:
            nonlocal fixed
            if off < fs.data_off or off + 32 > len(img):  # never touch FAT/root meta
                return
            first = img[off]
            if first in (0x00, 0xE5):
                return
            attr = img[off + 11]
            if attr == 0x0F:  # LFN slot: no time fields
                return

            def w16(o: int, v: int):
                nonlocal fixed
                if struct.unpack_from("<H", img, o)[0] != v:
                    struct.pack_into("<H", img, o, v)
                    fixed += 1

            if img[off + 13] != 0:
                img[off + 13] = 0
                fixed += 1
            w16(off + 14, t)  # CrtTime
            w16(off + 16, d)  # CrtDate
            w16(off + 18, d)  # LstAccDate
            w16(off + 22, t)  # WrtTime
            w16(off + 24, d)  # WrtDate

        def walk_dir(off: int, size: int):
            subdirs = []
            for i in range(0, size, 32):
                e = off + i
                fix_entry(e)
                first = img[e]
                attr = img[e + 11]
                name = bytes(img[e : e + 11])
                if (
                    first not in (0x00, 0xE5)
                    and attr != 0x0F
                    and attr & 0x10
                    and name not in (b".          ", b"..         ")
                ):
                    subdirs.append(struct.unpack_from("<H", img, e + 26)[0])
            return subdirs

        if fs.is32:
            pending = [fs.root_cluster]
        else:
            pending = walk_dir(fs.root_off, fs.root_bytes)
        seen = set()
        while pending:
            c = pending.pop()
            while 2 <= c < fs.eoc and c not in seen:
                seen.add(c)
                off = fs.cluster_off(c)
                pending += walk_dir(off, fs.clus_bytes)
                c = fs.fat_ent(c)

        f.seek(0)
        f.write(img)
    return fixed


if __name__ == "__main__":
    image = sys.argv[1]
    ep = int(sys.argv[2]) if len(sys.argv) > 2 else 1731494400
    n = normalize(image, ep)
    kind = "FAT32" if Fat(open(image, "rb").read(512)).is32 else "FAT16"
    print(f"fat-normalize: {kind}, pinned {n} time fields to epoch {ep}")
    sys.exit(0)


