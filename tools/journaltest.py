#!/usr/bin/env python3
"""SwiftFS journal fault-injection test — kill QEMU mid-write, verify.

Proves the SwiftFS metadata journal (Kernel/SwiftFS.swift) keeps the disk
consistent across hard power cuts:

  cycle = boot -> inject a deterministic burst of file writes/mkdirs/mvs
          (plus one overwrite of a seeded file) -> SIGKILL mid-burst
          -> offline fsck (structure + exact contents + prefix property)
          -> boot again -> journal replay on serial -> fsck again.

Phases:
  1. fresh blank 32 MiB image: format-with-journal path, then 3 kill cycles
     on the SAME image (each cycle's burst uses fresh cycle-tagged paths,
     so expectations accumulate deterministically)
  2. legacy image (a copy of the repo's pre-journal build/disk.img):
     must mount in journaled-off legacy mode, logged, fully usable

Assertions:
  * '[fs] formatted: ... journal 21 slots' on the blank-format boot
  * '[fs] journal replayed N records' on every post-kill mount (N >= 1
    over the run), '[fs] journal: clean' after quiescent reboots
  * '[fs] legacy image (no journal region)' for the old image
  * fsck PASS after every kill AND after every replay boot: every burst
    file is either fully present with byte-exact contents or fully
    absent, the executed ops form a prefix of the sent ones, no phantom
    paths, no overlapping spans, no freed-but-referenced blocks
  * no KERNEL PANIC / exception markers on any serial capture

Usage:
  python3 tools/journaltest.py [--elf build/swiftos.elf] [--workdir build]
                               [--cycles 3] [--seed 1234] [--keep-logs]
Stdlib only. Exit 0 iff every assertion passes.
"""

import argparse
import json
import os
import random
import shutil
import socket
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FSCK = os.path.join(ROOT, "tools", "fsck_swiftfs.py")

QEMU_BASE = [
    "qemu-system-aarch64", "-M", "virt", "-cpu", "cortex-a76", "-m", "8192",
    "-smp", "4",
    "-device", "ramfb",
    "-device", "virtio-keyboard-device",
    "-device", "virtio-tablet-device",
    "-netdev", "user,id=n0",
    "-device", "virtio-net-device,netdev=n0",
    "-global", "virtio-mmio.force-legacy=on",
]

LOGIN_NEEDLE = b"login session started"
MOUNTED_NEEDLE = b"[fs] mounted:"
FORMAT_NEEDLE = b"[fs] formatted:"
JOURNAL_CLEAN = b"[fs] journal: clean"
JOURNAL_REPLAY = b"[fs] journal replayed"
LEGACY_NEEDLE = b"[fs] legacy image (no journal region)"
DISK_ONLINE = b"persistent storage online"

PANIC_MARKERS = [
    b"KERNEL PANIC", b"SYNC EXCEPTION", b"RECURSIVE FAULT",
    b"stack overflow in thread", b"CPU_ON failed", b"[heap] bad free",
    b"heap validation FAILED", b"OUT OF MEMORY", b"SERROR",
]
PROBE_DONE = b"[probe] heap probes done"

SPLASH_SETTLE_S = 12.0     # boot splash eats keys (~3.5 s kernel time, TCG)
CMD_GAP_S = 0.12
NOTES_PATH = "/home/user/notes.txt"
# Original seeded contents of notes.txt (Userland/VFS.swift seedTree).
NOTES_SEED = (
    "Shopping list\n"
    "- oat milk\n"
    "- coffee beans\n"
    "- USB-C cable\n"
    "\n"
    "Ideas\n"
    "- finish the SwiftOS renderer\n"
    "- teach grep about regular expressions someday\n"
    "- remember: a backup is just a cp -r you have not done yet"
)

results = []


def record(name, ok, detail=""):
    results.append((name, ok, detail))
    line = f"{'PASS' if ok else 'FAIL'}  {name}"
    if detail:
        line += f"  ({detail})"
    print(line, flush=True)


# --------------------------------------------------------------------------
# serial plumbing (reader thread: QEMU + guest die asynchronously here)
# --------------------------------------------------------------------------

class Serial:
    def __init__(self, sock):
        self.sock = sock
        self.buf = bytearray()
        self.lock = threading.Lock()
        self.eof = False
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        while True:
            try:
                data = self.sock.recv(65536)
            except OSError:
                self.eof = True
                return
            if not data:
                self.eof = True
                return
            with self.lock:
                self.buf += data

    def snapshot(self):
        with self.lock:
            return bytes(self.buf)

    def find(self, needle, pos=0):
        with self.lock:
            return self.buf.find(needle, pos)

    def wait_for(self, needle, timeout, pos=0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            idx = self.find(needle, pos)
            if idx >= 0:
                return idx
            if self.eof:
                return -1
            time.sleep(0.05)
        return -1

    def wait_for_any(self, needles, timeout, pos=0):
        """First index where ANY needle matches at/after pos, or -1."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            hits = [self.find(n, pos) for n in needles]
            hits = [h for h in hits if h >= 0]
            if hits:
                return min(hits)
            if self.eof:
                return -1
            time.sleep(0.05)
        return -1

    def send(self, data: bytes):
        self.sock.sendall(data)

    def crash_markers(self):
        data = self.snapshot()
        probe_end = data.find(PROBE_DONE)
        hits = []
        for m in PANIC_MARKERS:
            idx = data.find(m)
            while idx >= 0 and probe_end >= 0 and idx < probe_end and m == b"[heap] bad free":
                idx = data.find(m, idx + 1)
            if idx >= 0:
                start = data.rfind(b"\n", 0, idx) + 1
                end = data.find(b"\n", idx)
                hits.append(data[start:end if end >= 0 else len(data)]
                            .decode(errors="replace").strip()[:160])
        return hits


class VM:
    """One QEMU instance with the journal test image attached."""

    def __init__(self, tag, elf, image, workdir):
        self.tag = tag
        self.sock_path = os.path.join(workdir, f"journal-{tag}.sock")
        try:
            os.unlink(self.sock_path)
        except FileNotFoundError:
            pass
        self.serial_log = os.path.join(workdir, f"journal-serial-{tag}.log")
        cmd = (QEMU_BASE + ["-display", "none",
                            "-serial", f"unix:{self.sock_path},server=on,wait=on",
                            "-device", "virtio-blk-device,drive=hd0",
                            "-drive", f"file={image},format=raw,if=none,id=hd0",
                            "-kernel", elf])
        self.proc = subprocess.Popen(
            cmd, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        sock = None
        deadline = time.monotonic() + 30.0
        while time.monotonic() < deadline:
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.connect(self.sock_path)
                break
            except OSError:
                if sock is not None:
                    sock.close()
                sock = None
                if self.proc.poll() is not None:
                    raise RuntimeError(f"QEMU exited ({self.proc.returncode}) before connect")
                time.sleep(0.05)
        if sock is None:
            raise TimeoutError("serial connect timeout")
        self.serial = Serial(sock)

    def hard_kill(self):
        """kill -9: instant power cut, no atexit, no flush."""
        if self.proc.poll() is None:
            self.proc.kill()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass

    def close(self, keep_log=True):
        self.hard_kill()
        try:
            self.serial.sock.close()
        except OSError:
            pass
        if keep_log:
            with open(self.serial_log, "wb") as fh:
                fh.write(self.serial.snapshot())
        try:
            os.unlink(self.sock_path)
        except FileNotFoundError:
            pass


# --------------------------------------------------------------------------
# burst construction
# --------------------------------------------------------------------------

def payload_line(cycle, tag):
    body = (f"c{cycle}x{tag}-" * 24)[:120]
    return f"JNPAY cycle={cycle} op={tag} {body}"


def build_burst(cycle, notes_prevs):
    """Deterministic op list for one cycle. Returns (ops, commands) where
    ops are the fsck manifest entries and commands the shell lines."""
    ops, cmds = [], []

    def write_op(tag, path):
        content = payload_line(cycle, tag) + "\n"
        ops.append({"type": "write", "path": path, "content": content})
        cmds.append(f"echo {payload_line(cycle, tag)} > {path}")

    for i in range(7):
        write_op(f"w{i}", f"/tmp/j{cycle}_{i}.txt")
    for d in ("a", "b"):
        ops.append({"type": "mkdir", "path": f"/tmp/jd{cycle}{d}"})
        cmds.append(f"mkdir /tmp/jd{cycle}{d}")
    for i in range(2):
        src = f"/tmp/jmv{cycle}_{i}.txt"
        dst = f"/tmp/jd{cycle}{'ab'[i]}/mv{cycle}_{i}.txt"
        content = payload_line(cycle, f"mv{i}") + "\n"
        # one op per pair: the mv visibility check subsumes the source write
        # (src-present = write landed, mv not yet; dst-present+src-gone =
        # both landed); one shell line keeps ops and commands index-aligned
        ops.append({"type": "mv", "src": src, "dst": dst, "content": content})
        cmds.append(f"echo {payload_line(cycle, f'mv{i}')} > {src}; mv {src} {dst}")
    notes_content = payload_line(cycle, "notes") + "\n"
    ops.append({"type": "overwrite", "path": NOTES_PATH,
                "content": notes_content, "prevs": list(notes_prevs)})
    cmds.append(f"echo {payload_line(cycle, 'notes')} > {NOTES_PATH}")
    for i in range(7, 13):
        write_op(f"w{i}", f"/tmp/j{cycle}_{i}.txt")
    ops.append({"type": "mkdir", "path": f"/tmp/jd{cycle}c"})
    cmds.append(f"mkdir /tmp/jd{cycle}c")
    for i in range(13, 16):
        write_op(f"w{i}", f"/tmp/j{cycle}_{i}.txt")
    return ops, cmds


def run_fsck(image, manifest_path, report_path):
    proc = subprocess.run(
        [sys.executable, FSCK, image, "--expect", manifest_path,
         "--json", report_path],
        capture_output=True, text=True)
    tail = proc.stdout.strip().splitlines()[-1] if proc.stdout.strip() else proc.stderr.strip()
    return proc.returncode == 0, tail, report_path


# --------------------------------------------------------------------------
# phases
# --------------------------------------------------------------------------

def wait_boot(vm, tag):
    idx = vm.serial.wait_for(LOGIN_NEEDLE, 180.0)
    record(f"{tag}: boot to login", idx >= 0,
           "" if idx >= 0 else "no 'login session started' in 180s")
    if idx < 0:
        return False
    time.sleep(SPLASH_SETTLE_S)
    vm.serial.send(b"ls /\n")   # first VFS access forces Disk.initAndMount
    # blank image -> format logs '[fs] formatted:'; existing image -> mount
    # logs '[fs] mounted:'; a missing/broken disk -> '[disk] ... RAM-only'.
    m = vm.serial.wait_for_any(
        (MOUNTED_NEEDLE, FORMAT_NEEDLE, b"[disk] no block device"), 60.0)
    ok = m >= 0
    record(f"{tag}: disk mounted or formatted", ok,
           "" if ok else "no [fs]/[disk] storage line in 60s")
    return ok


def kill_and_check_serial(vm, tag):
    vm.hard_kill()
    time.sleep(0.3)   # let the reader thread drain the socket
    hits = vm.serial.crash_markers()
    record(f"{tag}: no panic/exception markers", not hits,
           "; ".join(hits[:2]) if hits else "serial clean")


def cycle_phase(cycle, args, image, rng, notes_prevs, cycle_replays):
    ops, cmds = build_burst(cycle, notes_prevs)
    n_ops = len(ops)
    kill_after = rng.randrange(n_ops // 2, n_ops - 2)
    sent_ops = ops[:kill_after + 1]
    sent_cmds = cmds[:kill_after + 1]
    absent = []
    for op in ops[kill_after + 1:]:
        if op["type"] in ("write", "mkdir"):
            absent.append(op["path"])
        elif op["type"] == "mv":
            # pair is a single compound command: unsent means neither the
            # write nor the mv ever ran
            absent.extend([op["src"], op["dst"]])
        # overwrite targets pre-exist (seeded file) — never an absent marker

    # --- boot A: mount (replay of the previous cycle's tail), then burst --
    vm = VM(f"c{cycle}a", args.elf, image, args.workdir)
    try:
        if not wait_boot(vm, f"cycle{cycle}-bootA"):
            return False
        serial0 = vm.serial.snapshot()
        if cycle == 1:
            ok = serial0.find(FORMAT_NEEDLE) >= 0 and b"journal 21 slots" in serial0
            record("cycle1: blank disk formatted WITH journal", ok,
                   "expect '[fs] formatted: ... journal 21 slots'")
        else:
            # previous cycle's boot B replayed + checkpointed, then only
            # reads — this mount must be clean
            replay_idx = serial0.find(JOURNAL_REPLAY)
            clean_idx = serial0.find(JOURNAL_CLEAN)
            record(f"cycle{cycle}-bootA: post-quiescent mount is clean",
                   clean_idx >= 0,
                   "previous boot wrote nothing after its replay checkpoint")

        for line in sent_cmds:
            vm.serial.send(line.encode() + b"\n")
            time.sleep(CMD_GAP_S)
        time.sleep(rng.uniform(0.0, 0.25))   # kill lands mid-churn
        kill_and_check_serial(vm, f"cycle{cycle}-burst")
    finally:
        vm.close()
    record(f"cycle{cycle}: killed mid-burst after {len(sent_cmds)}/{n_ops} ops sent",
           True, "SIGKILL, no shutdown")

    # --- offline fsck #1: pre-replay image -------------------------------
    manifest = {"ops": sent_ops, "absent": absent}
    manifest_path = os.path.join(args.workdir, f"journal-ops-c{cycle}.json")
    with open(manifest_path, "w") as fh:
        json.dump(manifest, fh, indent=1)
    pre_report = os.path.join(args.workdir, f"journal-fsck-c{cycle}-pre.json")
    ok, tail, _ = run_fsck(image, manifest_path, pre_report)
    record(f"cycle{cycle}: fsck pre-replay (killed image)", ok, tail)

    # --- boot B: journal replay ------------------------------------------
    vm = VM(f"c{cycle}b", args.elf, image, args.workdir)
    try:
        if not wait_boot(vm, f"cycle{cycle}-bootB"):
            return False
        serial1 = vm.serial.snapshot()
        replay_idx = serial1.find(JOURNAL_REPLAY)
        replayed_n = -1
        line = ""
        if replay_idx >= 0:
            line_end = serial1.find(b"\n", replay_idx)
            line = serial1[replay_idx:line_end].decode(errors="replace")
            parts = line.split()
            # '[fs] journal replayed N records' -> N is the 4th word
            if len(parts) >= 4 and parts[3].isdigit():
                replayed_n = int(parts[3])
        # A kill exactly at a checkpoint boundary leaves nothing to replay
        # (clean mount) — legitimate; replay-with-N>=1 is asserted across
        # the whole run in main() via cycle_replays.
        cycle_replays.append(replayed_n)
        record(f"cycle{cycle}-bootB: journal state at mount",
               replayed_n >= 1 or serial1.find(JOURNAL_CLEAN) >= 0,
               line if replayed_n >= 1 else
               ("clean (kill landed on a checkpoint boundary)"
                if serial1.find(JOURNAL_CLEAN) >= 0 else "no journal line"))
        vm.serial.send(b"ls /tmp\n")   # exercise the hydrated tree
        time.sleep(1.5)                # idle: let the mount checkpoint land
        kill_and_check_serial(vm, f"cycle{cycle}-bootB")
    finally:
        vm.close()

    # --- offline fsck #2: post-replay image ------------------------------
    post_report = os.path.join(args.workdir, f"journal-fsck-c{cycle}-post.json")
    ok, tail, _ = run_fsck(image, manifest_path, post_report)
    record(f"cycle{cycle}: fsck post-replay", ok, tail)

    # --- visibility may only GROW across the replay ----------------------
    try:
        with open(pre_report) as fh:
            pre_vis = json.load(fh)["visibility"]
        with open(post_report) as fh:
            post_vis = json.load(fh)["visibility"]
        superset = all(not p or q for p, q in zip(pre_vis, post_vis))
        gained = sum(1 for p, q in zip(pre_vis, post_vis) if not p and q)
        record(f"cycle{cycle}: replay only completes ops (visibility superset)",
               superset, f"{gained} op(s) completed by replay")
    except (OSError, json.JSONDecodeError, KeyError) as exc:
        record(f"cycle{cycle}: replay visibility comparison", False, str(exc))
        return False

    notes_prevs.append(payload_line(cycle, "notes") + "\n")
    return ok


def legacy_phase(args, workdir_image):
    src = os.path.join(ROOT, "build", "disk.img")
    if not os.path.exists(src):
        record("legacy: repo build/disk.img present", False,
               "run `make disk` in the repo first")
        return False
    for _ in range(3):
        shutil.copyfile(src, workdir_image)
        if open(src, "rb").read() == open(workdir_image, "rb").read():
            break
        time.sleep(1.0)
    vm = VM("legacy", args.elf, workdir_image, args.workdir)
    try:
        if not wait_boot(vm, "legacy"):
            return False
        serial = vm.serial.snapshot()
        record("legacy: journaled-off mode logged",
               serial.find(LEGACY_NEEDLE) >= 0,
               "expect '[fs] legacy image (no journal region) — metadata journaling off'")
        record("legacy: persistent storage online",
               serial.find(DISK_ONLINE) >= 0)
        vm.serial.send(b"echo legacy-write > /tmp/legacyprobe.txt\n")
        time.sleep(1.0)
        kill_and_check_serial(vm, "legacy")
    finally:
        vm.close()
    proc = subprocess.run([sys.executable, FSCK, workdir_image],
                          capture_output=True, text=True)
    tail = proc.stdout.strip().splitlines()[-1] if proc.stdout.strip() else ""
    record("legacy: fsck structure PASS (no manifest)", proc.returncode == 0, tail)
    return proc.returncode == 0


def main():
    ap = argparse.ArgumentParser(description="SwiftFS journal kill-mid-write test")
    ap.add_argument("--elf", default=os.path.join(ROOT, "build", "swiftos.elf"))
    ap.add_argument("--workdir", default=os.path.join(ROOT, "build"),
                    help="where images/sockets/logs live")
    ap.add_argument("--cycles", type=int, default=3)
    ap.add_argument("--seed", type=int, default=0x5F5)
    args = ap.parse_args()
    rng = random.Random(args.seed)

    image = os.path.join(args.workdir, "journal-test.img")
    legacy_image = os.path.join(args.workdir, "journal-legacy.img")

    print("== SwiftFS journal fault-injection test ==", flush=True)
    print(f"[info] elf: {args.elf}", flush=True)
    if not os.path.exists(args.elf):
        record("elf present", False, args.elf)
        sys.exit(1)

    # fresh blank 32 MiB image (all zeros => 'no valid image' => format)
    with open(image, "wb") as fh:
        fh.truncate(32 * 1024 * 1024)
    record("fresh blank 32 MiB image", True, os.path.relpath(image, ROOT))

    notes_prevs = [NOTES_SEED]
    cycle_replays = []
    ok = True
    for cycle in range(1, args.cycles + 1):
        print(f"[info] --- cycle {cycle}/{args.cycles} ---", flush=True)
        if not cycle_phase(cycle, args, image, rng, notes_prevs, cycle_replays):
            ok = False
            break

    if ok:
        demonstrated = sum(1 for n in cycle_replays if n >= 1)
        record(f"journal replay demonstrated (>= {min(2, args.cycles)} cycles)",
               demonstrated >= min(2, args.cycles),
               f"replay counts per cycle: {cycle_replays}")
        print("[info] --- legacy image phase ---", flush=True)
        legacy_phase(args, legacy_image)

    print("== summary ==", flush=True)
    failed = [r for r in results if not r[1]]
    for name, ok_, detail in results:
        if not ok_:
            print(f"  FAIL  {name}  ({detail})", flush=True)
    print(f"{len(results) - len(failed)}/{len(results)} checks passed", flush=True)
    sys.exit(0 if not failed else 1)


if __name__ == "__main__":
    main()
