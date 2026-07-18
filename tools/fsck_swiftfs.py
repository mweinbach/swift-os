#!/usr/bin/env python3
"""Offline SwiftFS consistency checker (fsck) for SwiftOS disk images.

Pure-stdlib. Parses the on-disk layout exactly as Kernel/SwiftFS.swift
defines it (512-byte sectors, little-endian):

  sector 0     superblock  (magic "SWFS0001"; +44 journalStart u32,
                            +48 journalSectors u32; both 0 = legacy image)
  1 ..< 33     inode table (256 x 64 B)
  bitmapStart  free bitmap (1 bit per 4 KiB data block)
  journalStart metadata journal (journaled images only):
                 sector 0: journal superblock "JNSB" + checkpointSeq
                 then N slots of 3 sectors: payload / header "JNHR" /
                 commit "JNCM"
  dataStart    data blocks, 8 sectors each

Checks (ERRORs unless noted):
  * superblock magic + geometry sanity (both layouts)
  * inode 0 is the root directory; every live inode has a valid type,
    a zero-padded UTF-8 name and a live-directory parent; every inode
    reaches the root (no orphans, no cycles); no duplicate (parent, name)
  * file spans lie inside the data area, cover size, and never overlap
  * every block referenced by a live file has its bitmap bit set
    (clear => corruption); set-but-unreferenced bits are only WARNED
    about — the journaled write path leaks blocks by design when a
    power cut lands between "flip the inode" and "free the old span"
  * journal: superblock + per-slot magic/checksum validation; reports
    how many committed records are still pending replay (normal right
    after a kill) and the next sequence number

With --expect MANIFEST (JSON {"ops": [...]}), additionally verifies the
crash-consistency contract for a known burst of operations:
  * visibility per op —
      write:     file exists with EXACT content (never torn, never phantom)
      mkdir:     directory exists
      mv:        dst exists with exact content AND src is gone
      overwrite: content equals the new payload (visible) or one of the
                 known previous payloads (not yet executed) — never
                 anything else, never empty
  * prefix property — the executed ops form a prefix of the sent ops:
    some k with ops[0..k] all visible and ops[k+1..] all invisible
    (op k itself is the kill point: either state).

Usage:
  fsck_swiftfs.py IMAGE [--expect ops.json] [--json report.json] [-v]
Exit code 0 = consistent (warnings allowed), 1 = errors found.
"""

import argparse
import json
import struct
import sys

SECTOR = 512
INODE_COUNT = 256
INODE_SIZE = 64
IT_START = 1
IT_SECTORS = 32
BLOCK_SECTORS = 8
BLOCK_BYTES = BLOCK_SECTORS * SECTOR

O_NAME, O_TYPE, O_PARENT, O_FLAGS = 0, 44, 45, 46
O_SIZE, O_FIRST, O_COUNT, O_MTIME = 48, 52, 56, 60
T_FREE, T_FILE, T_DIR = 0, 1, 2

J_MAGIC_SUPER = 0x4A4E5342   # "JNSB"
J_MAGIC_HEADER = 0x4A4E4852  # "JNHR"
J_MAGIC_COMMIT = 0x4A4E434D  # "JNCM"


def fnv1a(data: bytes) -> int:
    h = 0x811C9DC5
    for b in data:
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return h


def u32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def u64(buf, off):
    return struct.unpack_from("<Q", buf, off)[0]


class Image:
    def __init__(self, path):
        with open(path, "rb") as fh:
            self.data = fh.read()
        self.sectors = len(self.data) // SECTOR

    def sector(self, lba):
        off = lba * SECTOR
        return self.data[off:off + SECTOR]

    def span(self, lba, count):
        off = lba * SECTOR
        return self.data[off:off + count * SECTOR]


class Fsck:
    def __init__(self, img, verbose=False):
        self.img = img
        self.verbose = verbose
        self.errors = []
        self.warnings = []
        self.info = []
        self.inodes = {}          # index -> dict (live inodes only)
        self.journal = {"present": False}
        self.paths = {}           # path -> inode index

    def err(self, msg):
        self.errors.append(msg)

    def warn(self, msg):
        self.warnings.append(msg)

    def note(self, msg):
        self.info.append(msg)

    # ---------------- superblock + tables ----------------

    def parse(self):
        img = self.img
        if img.sectors < 34:
            self.err(f"image too small ({img.sectors} sectors)")
            return False
        sb = img.sector(0)
        if sb[0:8] != b"SWFS0001":
            self.err("bad superblock magic")
            return False
        self.total = u64(sb, 8)
        inodes = u32(sb, 16)
        it_start = u32(sb, 20)
        it_sectors = u32(sb, 24)
        self.bm_start = u32(sb, 28)
        self.bm_sectors = u32(sb, 32)
        self.data_start = u32(sb, 36)
        blk_sectors = u32(sb, 40)
        self.j_start = u32(sb, 44)
        self.j_sectors = u32(sb, 48)
        if (inodes, it_start, it_sectors, blk_sectors) != \
           (INODE_COUNT, IT_START, IT_SECTORS, BLOCK_SECTORS):
            self.err(f"unexpected geometry: inodes={inodes} it={it_start}+{it_sectors} "
                     f"blk_sectors={blk_sectors}")
            return False
        if self.bm_start != IT_START + IT_SECTORS or self.bm_sectors < 1:
            self.err(f"bad bitmap geometry: start={self.bm_start} sectors={self.bm_sectors}")
            return False
        legacy = self.j_sectors == 0
        if legacy:
            if self.j_start != 0 or self.data_start != self.bm_start + self.bm_sectors:
                self.err("legacy layout mismatch (journalStart/dataStart)")
                return False
        else:
            if self.j_start != self.bm_start + self.bm_sectors or \
               self.data_start != self.j_start + self.j_sectors or \
               self.j_sectors < 4 or (self.j_sectors - 1) % 3 != 0:
                self.err(f"journal geometry mismatch: j={self.j_start}+{self.j_sectors} "
                         f"data_start={self.data_start}")
                return False
        if self.total > img.sectors or self.data_start >= self.total:
            self.err(f"totalSectors={self.total} beyond image size {img.sectors}")
            return False
        self.data_blocks = (self.total - self.data_start) // BLOCK_SECTORS
        self.table = img.span(IT_START, IT_SECTORS)
        self.bitmap = img.span(self.bm_start, self.bm_sectors)
        self.note(f"{'legacy (no journal)' if legacy else 'journaled'} image: "
                  f"{self.total} sectors, {self.data_blocks} data blocks")
        return True

    # ---------------- journal ----------------

    def check_journal(self):
        if self.j_sectors == 0:
            return
        j = {"present": True, "slots": (self.j_sectors - 1) // 3,
             "checkpoint_seq": 0, "valid_records": 0, "pending_replay": 0,
             "invalid_slots": 0, "highest_seq": 0, "records": []}
        jsb = self.img.sector(self.j_start)
        if u32(jsb, 0) == J_MAGIC_SUPER and u32(jsb, 8) == fnv1a(jsb[0:8]):
            j["checkpoint_seq"] = u32(jsb, 4)
        else:
            self.warn("journal superblock corrupt (checkpoint lost; harmless — "
                      "mount replays from seq 1)")
        for slot in range(j["slots"]):
            base = self.j_start + 1 + slot * 3
            payload = self.img.sector(base)
            hdr = self.img.sector(base + 1)
            cmt = self.img.sector(base + 2)
            ok = (u32(hdr, 0) == J_MAGIC_HEADER and
                  u32(hdr, 20) == fnv1a(hdr[0:20]) and
                  u32(cmt, 0) == J_MAGIC_COMMIT and
                  u32(cmt, 4) == u32(hdr, 4) and
                  u32(cmt, 8) == fnv1a(cmt[0:8]) and
                  u32(hdr, 16) == fnv1a(payload))
            if not ok:
                # an all-zero slot is just unused
                if hdr != bytes(SECTOR) or cmt != bytes(SECTOR):
                    j["invalid_slots"] += 1
                continue
            seq = u32(hdr, 4)
            j["valid_records"] += 1
            j["highest_seq"] = max(j["highest_seq"], seq)
            if seq > j["checkpoint_seq"]:
                j["pending_replay"] += 1
                j["records"].append({"seq": seq, "lba": u64(hdr, 8)})
        self.journal = j
        self.note(f"journal: {j['valid_records']} committed records in "
                  f"{j['slots']} slots, checkpoint seq {j['checkpoint_seq']}, "
                  f"{j['pending_replay']} pending replay")
        for rec in j["records"]:
            if rec["lba"] + 1 > self.total:
                self.err(f"journal record seq {rec['seq']} targets out-of-range "
                         f"sector {rec['lba']}")

    # ---------------- inode table ----------------

    def parse_inodes(self):
        for i in range(INODE_COUNT):
            b = i * INODE_SIZE
            t = self.table[b + O_TYPE]
            if t == T_FREE:
                # free slots must be fully zeroed (no phantom fields)
                if any(self.table[b:b + INODE_SIZE]):
                    self.err(f"inode {i}: marked free but not zeroed")
                continue
            if t not in (T_FILE, T_DIR):
                self.err(f"inode {i}: bogus type {t}")
                continue
            raw = self.table[b + O_NAME:b + O_NAME + 44]
            nul = raw.find(b"\0")
            name_bytes = raw if nul < 0 else raw[:nul]
            if nul >= 0 and any(raw[nul:]):
                self.err(f"inode {i}: name not zero-padded")
            try:
                name = name_bytes.decode("utf-8")
            except UnicodeDecodeError:
                self.err(f"inode {i}: name not valid UTF-8")
                name = "?"
            if not name_bytes:
                self.err(f"inode {i}: empty name")
            self.inodes[i] = {
                "index": i, "type": t, "name": name, "parent": self.table[b + O_PARENT],
                "flags": struct.unpack_from("<H", self.table, b + O_FLAGS)[0],
                "size": u32(self.table, b + O_SIZE),
                "first": u32(self.table, b + O_FIRST),
                "count": u32(self.table, b + O_COUNT),
                "mtime": u32(self.table, b + O_MTIME),
            }
        if 0 not in self.inodes or self.inodes[0]["type"] != T_DIR:
            self.err("inode 0 is not a live directory (no root)")
        elif self.inodes[0]["parent"] != 0 or self.inodes[0]["name"] != "/":
            self.err("root inode has wrong parent or name")

    def check_tree(self):
        # parent validity + reachability + cycle detection
        for i, ino in self.inodes.items():
            if i == 0:
                continue
            seen = set()
            cur = i
            while True:
                if cur == 0:
                    break
                node = self.inodes.get(cur)
                if node is None:
                    self.err(f"inode {i} ('{ino['name']}'): parent chain hits "
                             f"free inode {cur} (orphan)")
                    break
                if cur in seen:
                    self.err(f"inode {i} ('{ino['name']}'): cycle in parent chain")
                    break
                seen.add(cur)
                p = node["parent"]
                parent = self.inodes.get(p)
                if parent is None:
                    self.err(f"inode {i} ('{ino['name']}'): parent {p} is free (orphan)")
                    break
                if parent["type"] != T_DIR:
                    self.err(f"inode {i} ('{ino['name']}'): parent {p} is not a directory")
                    break
                cur = p
        # duplicate (parent, name)
        seen_names = {}
        for i, ino in self.inodes.items():
            if i == 0:
                continue
            key = (ino["parent"], ino["name"])
            if key in seen_names:
                self.err(f"duplicate name '{ino['name']}' under parent {ino['parent']} "
                         f"(inodes {seen_names[key]} and {i})")
            else:
                seen_names[key] = i
        # path map
        def path_of(i):
            parts = []
            cur = i
            while cur != 0:
                node = self.inodes[cur]
                parts.append(node["name"])
                cur = node["parent"]
                if len(parts) > INODE_COUNT:
                    return None
            return "/" + "/".join(reversed(parts))
        for i in self.inodes:
            p = path_of(i)
            if p is not None:
                self.paths[p] = i

    def check_spans_and_bitmap(self):
        spans = []
        for i, ino in self.inodes.items():
            if ino["type"] != T_FILE:
                continue
            size, first, count = ino["size"], ino["first"], ino["count"]
            if size == 0:
                if count != 0:
                    self.warn(f"inode {i} ('{ino['name']}'): size 0 with {count} "
                              f"blocks still allocated (legacy-style slack)")
                    spans.append((first, first + count, i))
                continue
            needed = (size + BLOCK_BYTES - 1) // BLOCK_BYTES
            if count < needed:
                self.err(f"inode {i} ('{ino['name']}'): size {size} needs {needed} "
                         f"blocks, span has {count}")
            if first + count > self.data_blocks:
                self.err(f"inode {i} ('{ino['name']}'): span [{first},{first + count}) "
                         f"past data area ({self.data_blocks} blocks)")
                continue
            spans.append((first, first + count, i))
        spans.sort()
        for (a0, a1, ia), (b0, b1, ib) in zip(spans, spans[1:]):
            if b0 < a1:
                self.err(f"data blocks [{b0},{min(a1, b1)}) claimed by BOTH inode {ia} "
                         f"and inode {ib}")
        # bitmap cross-check
        referenced = set()
        for first, last, i in spans:
            referenced.update(range(first, last))
        leaked = 0
        for blk in range(self.data_blocks):
            bit = (self.bitmap[blk // 8] >> (blk % 8)) & 1
            if blk in referenced and not bit:
                self.err(f"block {blk} referenced by a live inode but FREE in bitmap "
                         f"(would be reallocated)")
            elif blk not in referenced and bit:
                leaked += 1
        if leaked:
            self.warn(f"{leaked} data blocks marked used but unreferenced "
                      f"(crash-window leak; reclaimed only by reformat)")

    # ---------------- file contents ----------------

    def read_file(self, ino):
        size = ino["size"]
        if size == 0 or ino["count"] == 0:
            return b""
        lba = self.data_start + ino["first"] * BLOCK_SECTORS
        return self.img.span(lba, ino["count"] * BLOCK_SECTORS)[:size]

    # ---------------- expectations (burst manifest) ----------------

    def op_state(self, op):
        """Returns (visible, detail). visible=True/False; None content on dirs."""
        t = op["type"]
        if t == "write":
            idx = self.paths.get(op["path"])
            if idx is None:
                return False, "absent"
            content = self.read_file(self.inodes[idx])
            if content == op["content"].encode():
                return True, "present, exact content"
            return "BAD", f"present but content MISMATCH ({len(content)} bytes)"
        if t == "mkdir":
            idx = self.paths.get(op["path"])
            if idx is None:
                return False, "absent"
            if self.inodes[idx]["type"] != T_DIR:
                return "BAD", "present but NOT a directory"
            return True, "present"
        if t == "mv":
            src = self.paths.get(op["src"])
            dst = self.paths.get(op["dst"])
            if dst is not None:
                content = self.read_file(self.inodes[dst])
                if content != op["content"].encode():
                    return "BAD", "moved file content MISMATCH"
                if src is not None:
                    return "BAD", "src AND dst both exist after mv"
                return True, "moved"
            if src is not None:
                content = self.read_file(self.inodes[src])
                if content != op["content"].encode():
                    return "BAD", "unmoved src content MISMATCH"
                return False, "not moved yet"
            return False, "neither src nor dst present"
        if t == "overwrite":
            idx = self.paths.get(op["path"])
            if idx is None:
                return "BAD", "overwritten file is MISSING entirely"
            content = self.read_file(self.inodes[idx])
            if content == op["content"].encode():
                return True, "new content"
            if content.decode(errors="replace") in op.get("prevs", []):
                return False, "previous content (op not executed)"
            return "BAD", "content matches NEITHER new NOR any previous payload"
        raise ValueError(f"unknown op type {t}")

    def check_expect(self, ops, absent=()):
        visibility = []
        for n, op in enumerate(ops):
            state, detail = self.op_state(op)
            if state == "BAD":
                self.err(f"op {n} ({op['type']} {op.get('path', op.get('dst'))}): {detail}")
                visibility.append(False)
            else:
                visibility.append(bool(state))
                if self.verbose:
                    self.note(f"op {n:2d} {op['type']:9s} "
                              f"{'VISIBLE' if state else 'pending'} — {detail}")
        # prefix property: once an op is invisible, all later ops must be too
        first_invisible = None
        for n, vis in enumerate(visibility):
            if not vis and first_invisible is None:
                first_invisible = n
            elif vis and first_invisible is not None:
                self.err(f"op {n} is visible but earlier op {first_invisible} is not "
                         f"(execution was not a prefix — reordered or phantom writes)")
                break
        done = first_invisible if first_invisible is not None else len(ops)
        self.note(f"burst prefix: {done}/{len(ops)} ops landed before the kill")
        # paths no executed op may ever have created
        for path in absent:
            if path in self.paths:
                self.err(f"phantom path exists (op never executed): {path}")
        return visibility

    # ---------------- driver ----------------

    def run(self, expect_ops=None, expect_absent=()):
        ok = self.parse()
        if ok:
            self.check_journal()
            self.parse_inodes()
            self.check_tree()
            self.check_spans_and_bitmap()
            self.note(f"{len(self.inodes)} live inodes, {len(self.paths)} paths")
        visibility = None
        if expect_ops is not None and ok:
            visibility = self.check_expect(expect_ops, expect_absent)
        report = {
            "ok": not self.errors,
            "errors": self.errors,
            "warnings": self.warnings,
            "info": self.info,
            "journal": self.journal,
            "visibility": visibility,
            "paths": sorted(self.paths.keys()),
        }
        return report


def main():
    ap = argparse.ArgumentParser(description="Offline SwiftFS consistency checker")
    ap.add_argument("image")
    ap.add_argument("--expect", metavar="OPS.json",
                    help="burst manifest ({\"ops\": [...]}) to verify against")
    ap.add_argument("--json", metavar="REPORT.json", help="write full report here")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    img = Image(args.image)
    fsck = Fsck(img, verbose=args.verbose)
    ops = None
    absent = ()
    if args.expect:
        with open(args.expect) as fh:
            manifest = json.load(fh)
        ops = manifest["ops"]
        absent = manifest.get("absent", ())
    report = fsck.run(expect_ops=ops, expect_absent=absent)

    for line in report["info"]:
        print(f"  info: {line}")
    for line in report["warnings"]:
        print(f"  WARN: {line}")
    for line in report["errors"]:
        print(f"  ERR : {line}")
    verdict = "PASS" if report["ok"] else "FAIL"
    print(f"fsck {args.image}: {verdict} "
          f"({len(report['errors'])} errors, {len(report['warnings'])} warnings)")
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(report, fh, indent=2)
    sys.exit(0 if report["ok"] else 1)


if __name__ == "__main__":
    main()
