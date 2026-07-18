#!/usr/bin/env python3
"""SwiftOS smoke test — build, boot, and exercise the kernel end to end.

Usage:
    python3 tools/smoketest.py              # build + headless boot assertions + batteries
    python3 tools/smoketest.py --cocoa      # additionally: cocoa pass with window screenshots
    python3 tools/smoketest.py --with-disk  # attach a snapshot of build/disk.img and
                                            # REQUIRE persistent storage to come online
    python3 tools/smoketest.py --soak 60    # after the batteries: 60 s of seeded random
                                            # command/key injection with liveness checks
    python3 tools/smoketest.py --keep-qemu  # leave the LAST pass's QEMU running

What it does:
  1. Builds the kernel with `make` (retries a few times — concurrent agents
     build in the same directory).
  2. Boots QEMU headless with the serial console on a unix socket and asserts
     the boot log lines appear IN ORDER, each with its own timeout:
         heap self-test ok -> gic -> [sched] scheduler up -> [fb] ramfb
         -> [input] virtio keyboard -> [net] ipv4 -> login session started
     The order matches the real boot sequence in Kernel/Main.swift (sched ->
     display -> input -> net, all synchronous before the compositor starts).
     The socket uses `wait=on` (NOT the usual `wait=off`): the guest boots in
     well under a second and then goes quiet on serial, so with wait=off every
     boot byte is written before a client can possibly connect and is silently
     dropped. wait=on holds the guest until our client is attached — fully
     deterministic capture. The make product is also snapshotted to
     build/swiftos-smoke.elf first, so a concurrent agent's rebuild can't swap
     a half-written ELF under QEMU.
  3. Waits out the boot splash (~3.5 s of kernel uptime ~ 12 s wall under TCG)
     and injects the standard shell command battery through the serial socket.
     Shell output goes to the GUI, not serial — this exercises the input path.
     Afterwards asserts QEMU is still alive and no panic/exception dump hit
     the serial console.
  4. Storage assertion: Disk.initAndMount() is LAZY (first VFS access, see
     Userland/VFS.swift), so the storage line is not a boot line — it is
     checked after the standard battery (its `ls /` forces the mount).
     Default (no disk attached): 'persistent storage online' OR 'RAM-only'
     both pass. --with-disk: a stable snapshot of build/disk.img is attached
     (build/smoke-disk.img, so the stress battery never mutates the real
     image and another agent's QEMU holding the image doesn't block us) and
     persistence MUST come online — 'persistent storage online' for an
     already-formatted image, 'fresh image formatted and seeded' /
     'empty image reseeded' for a blank one (both mean write-through is
     live); any 'RAM-only' outcome fails.
  5. Stress battery: ~30 more injected command lines, most of them
     `;`-chained compounds (mkdir/echo/mv/cp/cat/rm loops, pipes, append
     redirection), plus the real workloads: ping -c 1 10.0.2.2 (twice, once
     after the filesystem churn), udemo (twice — EL0 re-entry), tree /,
     du -sh /, find /, man/which lookups, kill 9999 (expect-safe failure),
     and `top` followed 3 s later by a bare `q` to exercise the terminal's
     interactive TOP mode entry/exit, then a final `uptime` to prove the
     shell is responsive again.
  6. Negative assertions across the WHOLE run (from the first boot byte to
     the last soak key): the serial log must not contain KERNEL PANIC,
     SYNC EXCEPTION, RECURSIVE FAULT, [heap] bad free, heap validation
     FAILED, OUT OF MEMORY, or SERROR — the offending line is quoted on
     failure.
  7. --soak N: after the batteries, injects randomized-but-seeded command
     sequences plus arrow/escape key bytes for N seconds, asserting QEMU
     stays alive and no crash marker appears (liveness only — no serial
     heartbeat required), then a final 'uptime' injection.
  8. With --cocoa: boots a second instance with `-display cocoa`, captures
     window screenshots into build/smoke-shots/ (CGWindowList via an
     `xcrun swift -` one-liner + `screencapture -l`) and does cheap pixel
     assertions with a tiny pure-python PNG reader: the top panel of the
     desktop (#191C21 ±8) fills the guest's top 32 rows — the guest content
     sits below the macOS title bar in the capture, so "top" means the first
     panel-colored band within the top eighth of the image, allowing a 1px
     separator hairline — and the terminal background #0D0F13 appears on at
     least a few rows (1px hairlines elsewhere don't count). The cocoa pass
     runs the same batteries (so the screenshots exercise real rendering),
     but not the soak.

Stdlib only. Exit code 0 iff every assertion passes.
"""

import argparse
import filecmp
import os
import random
import shutil
import socket
import struct
import subprocess
import sys
import time
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build")
ELF = os.path.join(BUILD, "swiftos.elf")
ELF_SNAPSHOT = os.path.join(BUILD, "swiftos-smoke.elf")
DISK_IMG = os.path.join(BUILD, "disk.img")
DISK_SNAPSHOT = os.path.join(BUILD, "smoke-disk.img")
SOCK_HEADLESS = os.path.join(BUILD, "smoke.sock")
SOCK_COCOA = os.path.join(BUILD, "smoke-cocoa.sock")
SHOTS_DIR = os.path.join(BUILD, "smoke-shots")

QEMU = "qemu-system-aarch64"
QEMU_BASE = [
    QEMU, "-M", "virt", "-cpu", "cortex-a76", "-m", "8192", "-smp", "4",
    "-device", "ramfb",
    "-device", "virtio-keyboard-device",
    "-device", "virtio-tablet-device",
    "-netdev", "user,id=n0",
    "-device", "virtio-net-device,netdev=n0",
    "-global", "virtio-mmio.force-legacy=on",
]

# virtio-blk is appended only with --with-disk (probing is by device ID, so
# slot order vs. the Makefile's layout doesn't matter).
DISK_QEMU_ARGS = [
    "-device", "virtio-blk-device,drive=hd0",
    "-drive", f"file={DISK_SNAPSHOT},format=raw,if=none,id=hd0",
]

# (needle, per-step timeout s) — asserted strictly in order. The order is the
# real boot sequence in kmain: Heap -> Interrupts -> Scheduler -> Display ->
# Input -> Net (all synchronous) -> compositor session.
BOOT_STEPS = [
    (b"heap self-test ok", 90.0),
    (b"gic", 45.0),
    (b"[sched] scheduler up", 45.0),
    (b"[fb] ramfb", 45.0),
    (b"[input] virtio keyboard", 45.0),
    (b"[net] ipv4", 45.0),
    (b"login session started", 60.0),
]

# Storage lines (Userland/VFS.swift Disk.initAndMount) — logged LAZILY on the
# first VFS access, so asserted after the standard battery, not at boot.
STORAGE_ONLINE = b"persistent storage online"
STORAGE_ONLINE_ALTS = (b"fresh image formatted and seeded",  # blank image path
                       b"empty image reseeded")              # valid-but-empty path
STORAGE_RAM_ONLY = b"RAM-only"

BATTERY = [
    "uname -a",
    "ls /",
    "ps",
    "mkdir /tmp/smoke",
    "echo hello > /tmp/smoke/f.txt",
    "cat /tmp/smoke/f.txt",
    "rm -r /tmp/smoke",
    "neofetch",
]

# Stress battery: (line, settle seconds after injecting). Compounds exercise
# the `;` sequencer, pipes, `>`/`>>` redirection, and multi-operand commands;
# everything touches only /tmp (or read-only paths) so it is safe to repeat
# against a persistent disk. kill/ping/which/missing-operand lines are
# expect-safe error paths. The last entry must stay `top` — a bare `q` is
# injected after it to leave the terminal's interactive TOP mode.
STRESS_BATTERY = [
    ("mkdir /tmp/s1; echo a > /tmp/s1/f; mv /tmp/s1/f /tmp/s1/g; cat /tmp/s1/g; rm -r /tmp/s1", 2.5),
    ("mkdir /tmp/st1; mkdir /tmp/st1/a; mkdir /tmp/st1/b; echo one > /tmp/st1/a/f1; "
     "echo two > /tmp/st1/b/f2; cp /tmp/st1/a/f1 /tmp/st1/b/f3; ls /tmp/st1/b; rm -r /tmp/st1", 2.5),
    ("echo alpha > /tmp/w1; echo beta >> /tmp/w1; cat /tmp/w1; wc -l /tmp/w1; rm /tmp/w1", 2.5),
    ("touch /tmp/t1 /tmp/t2; ls /tmp; rm /tmp/t1 /tmp/t2", 2.5),
    ("cp /etc/hostname /tmp/h; cat /tmp/h; mv /tmp/h /tmp/h2; cat /tmp/h2; rm /tmp/h2", 2.5),
    ("mkdir /tmp/deep; mkdir /tmp/deep/d1; mkdir /tmp/deep/d1/d2; "
     "echo x > /tmp/deep/d1/d2/leaf; find /tmp/deep; rm -r /tmp/deep", 2.5),
    ("cat /etc/passwd | grep root; cat /etc/os-release | grep NAME", 2.5),
    ("head -n 3 /home/user/README.txt; tail -n 2 /home/user/notes.txt", 2.5),
    ("grep swift /home/user/notes.txt; wc /var/log/syslog", 2.5),
    ("ls /; ls /bin; ls /usr/bin; ls /etc", 2.5),
    ("df; free; uptime", 2.5),
    ("ps; history; env", 2.5),
    ("date; hostname; whoami; uname -a", 2.5),
    ("export STRESS=1; env | grep STRESS", 2.5),
    ("ping -c 1 10.0.2.2", 6.0),          # ARP resolve + ICMP echo via slirp
    ("udemo", 4.0),                       # EL0 userspace demo round-trip
    ("tree /", 4.0),
    ("du -sh /", 4.0),
    ("find /", 4.0),                      # no ls -R support; find is the walker
    ("cat /var/log/syslog", 3.0),         # lazily-rendered live boot log
    ("man ping", 2.5),
    ("man tree; man du; man top", 2.5),
    ("which kill", 2.5),
    ("which ping top udemo; which find man", 2.5),
    ("kill 9999", 2.5),                   # no such pid — expect-safe failure
    ("kill; kill abc", 2.5),              # usage + unparsable pid
    ("ping", 2.5),                        # usage error path
    ("ping -c 1 10.0.2.2", 6.0),          # net stack still alive after FS churn
    ("udemo", 4.0),                       # EL0 re-entry
    ("echo stress-ok > /tmp/last; cat /tmp/last; rm /tmp/last", 2.5),
    ("top", 3.0),                         # enters TOP mode; bare 'q' follows
]

# --soak: seeded-random picks from these (side-effect-light; no exit/
# shutdown/nano/open/top, no kills of real pids).
SOAK_COMMANDS = [
    "ls /", "ls /tmp", "ps", "uptime", "date", "hostname", "whoami",
    "uname -a", "df", "free", "env", "history",
    "cat /etc/hostname", "cat /etc/motd", "head -n 5 /home/user/README.txt",
    "wc /var/log/syslog", "grep root /etc/passwd", "find /etc", "tree /home",
    "du -sh /tmp", "which kill", "man ls",
    "echo soak > /tmp/soakf; cat /tmp/soakf; rm /tmp/soakf",
    "ping -c 1 10.0.2.2", "udemo",
]

# Arrow keys (ESC[A/B/C/D), bare ESC (abandon input), DEL, TAB (completion).
SOAK_KEYS = [b"\x1b[A", b"\x1b[B", b"\x1b[C", b"\x1b[D", b"\x1b", b"\x7f", b"\t"]
SOAK_SEED = 0x51F7

# Crash signatures that must NOT appear on serial across the whole run.
PANIC_MARKERS = [
    b"KERNEL PANIC",
    b"SYNC EXCEPTION",
    b"RECURSIVE FAULT",
    b"[heap] bad free",
    b"heap validation FAILED",
    b"OUT OF MEMORY",
    b"SERROR",
]

CONNECT_TIMEOUT = 30.0
SPLASH_SETTLE_S = 12.0   # boot splash ~3.5 s kernel uptime; TCG runs ~3x slow
CMD_GAP_S = 2.0
TOP_QUIT_SETTLE_S = 2.5  # bare 'q' to leave TOP mode, then prompt is back
POST_BATTERY_SETTLE_S = 4.0
MAKE_ATTEMPTS = 4
MAKE_RETRY_SLEEP_S = 8.0

PANEL_RGB = (0x19, 0x1C, 0x21)   # Color.panel — top panel, 32px tall
PANEL_TOL = 8                    # per spec: ±8 per channel
PANEL_WINDOW = 32                # "top 32 rows" of the guest content
PANEL_MIN_MATCH = 28             # of those 32 rows (1-2 px separator hairline)
TERM_RGB = (0x0D, 0x0F, 0x13)    # Color.terminalBackground
TERM_TOL = 4                     # screencapture is color-managed + dithered
TERM_MIN_ROWS = 3                # must appear on >=3 rows (1px hairlines don't count)

SWIFTC = os.path.expanduser(
    "~/Library/Developer/Toolchains/swift-6.2-RELEASE.xctoolchain/usr/bin/swiftc")

# Kernel/Heap.swift runs a boot-time probe suite that DELIBERATELY triggers a
# few bad frees to prove the detector works, logging "[heap] bad free ..." —
# the same signature a real bad free has. The probes are bracketed, ending at
# PROBE_DONE, so exactly the probe-emittable markers (PROBE_EXEMPT — note
# "[heap] bad free" also prefixes "bad freePages") are ignored before that
# line. If the probe line disappears, no exemption applies and the markers
# count everywhere (fail-noisy on a kernel-log change). Every other marker
# (panics, exceptions, OOM) counts anywhere, anytime.
PROBE_DONE = b"[probe] heap probes done"
PROBE_EXEMPT = (b"[heap] bad free",)

# CGWindowList one-liner (host macOS tool — Foundation rules don't apply here).
# Prints "<windowNumber>\t<ownerName>\t<windowName>" for layer-0 qemu windows.
WINDOW_FINDER_SWIFT = r"""
import CoreGraphics
if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                         kCGNullWindowID) as? [[String: Any]] {
    for w in list {
        let owner = (w[kCGWindowOwnerName as String] as? String ?? "")
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        guard owner.lowercased().contains("qemu"), layer == 0 else { continue }
        let num = w[kCGWindowNumber as String] as? Int ?? 0
        let name = w[kCGWindowName as String] as? String ?? ""
        print("\(num)\t\(owner)\t\(name)")
    }
}
"""

results = []  # list of (name, ok, detail)


def record(name, ok, detail=""):
    results.append((name, ok, detail))
    line = f"{'PASS' if ok else 'FAIL'}  {name}"
    if detail:
        line += f"  ({detail})"
    print(line, flush=True)


# --------------------------------------------------------------------------
# build
# --------------------------------------------------------------------------

def step_make():
    t0 = time.monotonic()
    last_out = ""
    for attempt in range(1, MAKE_ATTEMPTS + 1):
        proc = subprocess.run(["make"], cwd=ROOT, capture_output=True, text=True)
        if proc.returncode == 0 and os.path.exists(ELF):
            record("build: make", True,
                   f"{time.monotonic() - t0:.1f}s, attempt {attempt}")
            return snapshot_elf()
        last_out = (proc.stdout + proc.stderr).strip().splitlines()
        last_out = "\n".join(last_out[-12:])
        if attempt < MAKE_ATTEMPTS:
            print(f"[info] make attempt {attempt} failed (another agent building?); "
                  f"retrying in {MAKE_RETRY_SLEEP_S:.0f}s", flush=True)
            time.sleep(MAKE_RETRY_SLEEP_S)
    record("build: make", False, f"{MAKE_ATTEMPTS} attempts failed:\n{last_out}")
    return False


def snapshot_elf():
    """Copy the freshly built ELF aside so a concurrent `make` can't swap a
    half-written kernel under QEMU mid-boot. Retries until copy == source."""
    for attempt in range(1, 4):
        try:
            shutil.copyfile(ELF, ELF_SNAPSHOT)
            if filecmp.cmp(ELF, ELF_SNAPSHOT, shallow=False):
                record("build: stable elf snapshot", True,
                       os.path.relpath(ELF_SNAPSHOT, ROOT))
                return True
        except OSError:
            pass
        time.sleep(1.0)
    record("build: stable elf snapshot", False,
           "build/swiftos.elf keeps changing under us (concurrent builds)")
    return False


def snapshot_disk():
    """--with-disk: copy build/disk.img aside. The stress battery writes to
    the disk it boots with, and another agent's QEMU may hold the real image,
    so the guest always mounts build/smoke-disk.img, never the live one.
    Retries until the copy matches (image not changing under us)."""
    if not os.path.exists(DISK_IMG):
        record("build: disk image present", False,
               "build/disk.img missing — run `make disk`")
        return False
    for attempt in range(1, 4):
        try:
            shutil.copyfile(DISK_IMG, DISK_SNAPSHOT)
            if filecmp.cmp(DISK_IMG, DISK_SNAPSHOT, shallow=False):
                record("build: stable disk snapshot", True,
                       os.path.relpath(DISK_SNAPSHOT, ROOT))
                return True
        except OSError:
            pass
        time.sleep(1.0)
    record("build: stable disk snapshot", False,
           "build/disk.img keeps changing under us (another QEMU writing?)")
    return False


# --------------------------------------------------------------------------
# serial plumbing
# --------------------------------------------------------------------------

class SerialPump:
    """Accumulates everything the guest writes to the serial socket."""

    def __init__(self, sock, proc):
        self.sock = sock
        self.proc = proc
        self.buf = bytearray()
        self.total = 0
        self.eof = False

    def pump(self):
        if self.eof:
            return
        try:
            data = self.sock.recv(65536)
        except socket.timeout:
            return
        except OSError:
            self.eof = True
            return
        if data == b"":
            self.eof = True
        else:
            self.buf += data
            self.total += len(data)

    def drain_for(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.pump()
            time.sleep(0.05)

    def wait_for(self, needle, timeout, from_pos):
        """Ordered search: returns index of needle at/after from_pos, or -1."""
        deadline = time.monotonic() + timeout
        while True:
            idx = self.buf.find(needle, from_pos)
            if idx >= 0:
                return idx
            if self.eof or self.proc.poll() is not None:
                return -1
            if time.monotonic() >= deadline:
                return -1
            self.pump()

    def has_crash_since(self, pos):
        """First crash marker at/after pos, with its log line(s) as context.
        Probe-exempt markers (see PROBE_EXEMPT) are skipped inside the heap
        self-test probe window at boot."""
        probe_end = self.buf.find(PROBE_DONE)
        for marker in PANIC_MARKERS:
            idx = self.buf.find(marker, pos)
            while (idx >= 0 and probe_end >= 0 and idx < probe_end
                   and marker in PROBE_EXEMPT):
                idx = self.buf.find(marker, idx + 1)
            if idx < 0:
                continue
            start = self.buf.rfind(b"\n", 0, idx) + 1
            # include the line before (exception dumps precede the panic line)
            prev_nl = self.buf.rfind(b"\n", 0, max(start - 1, 0)) + 1
            if start > pos and prev_nl >= pos:
                start = prev_nl
            end = self.buf.find(b"\n", idx)
            if end < 0:
                end = len(self.buf)
            context = self.buf[start:end].decode(errors="replace").strip()
            return f"{marker.decode()}: {context[:200]}"
        return None


def launch_qemu(tag, display, sock_path, extra_args=()):
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass
    log_path = os.path.join(BUILD, f"smoke-qemu-{tag}.log")
    logf = open(log_path, "wb")
    # wait=on: hold the guest until our serial client connects (see module
    # docstring) — otherwise the whole boot log is emitted before connect.
    cmd = (QEMU_BASE + ["-display", display,
                        "-serial", f"unix:{sock_path},server=on,wait=on",
                        "-kernel", ELF_SNAPSHOT] + list(extra_args))
    proc = subprocess.Popen(cmd, cwd=ROOT, stdout=logf, stderr=subprocess.STDOUT)
    return proc, logf, log_path


def connect_serial(sock_path, proc, timeout=CONNECT_TIMEOUT):
    """Reconnect loop until QEMU's unix-socket serial server accepts us."""
    deadline = time.monotonic() + timeout
    while True:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(sock_path)
            sock.settimeout(0.2)
            return sock
        except OSError:
            sock.close()
            if proc.poll() is not None:
                raise RuntimeError(f"QEMU exited (code {proc.returncode}) before serial connect")
            if time.monotonic() >= deadline:
                raise TimeoutError(f"could not connect to {sock_path} in {timeout:.0f}s")
            time.sleep(0.05)


def save_serial(tag, pump):
    """Full serial capture of the pass, for post-mortem debugging."""
    if pump is None:
        return
    path = os.path.join(BUILD, f"smoke-serial-{tag}.log")
    try:
        with open(path, "wb") as fh:
            fh.write(bytes(pump.buf))
        print(f"[info] serial capture: {os.path.relpath(path, ROOT)}", flush=True)
    except OSError:
        pass


def stop_qemu(proc, sock, logf, keep):
    if sock is not None:
        try:
            sock.close()
        except OSError:
            pass
    if keep and proc.poll() is None:
        print(f"[info] --keep-qemu: leaving QEMU running (pid {proc.pid})", flush=True)
    elif proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
    logf.close()


# --------------------------------------------------------------------------
# boot + batteries
# --------------------------------------------------------------------------

def boot_pass(tag, display, sock_path, extra_args=(), with_disk=False):
    """Boot QEMU, assert the boot log. Returns (ok, proc, sock, pump, logf, session_pos)."""
    if with_disk:
        extra_args = list(extra_args) + DISK_QEMU_ARGS
    proc, logf, _ = launch_qemu(tag, display, sock_path, extra_args)
    sock = None
    try:
        sock = connect_serial(sock_path, proc)
    except (RuntimeError, TimeoutError) as exc:
        record(f"{tag}: serial connect", False, str(exc))
        return False, proc, sock, None, logf, -1
    pump = SerialPump(sock, proc)

    pos = 0
    t_prev = time.monotonic()
    for needle, timeout in BOOT_STEPS:
        idx = pump.wait_for(needle, timeout, pos)
        if idx < 0:
            why = ("serial EOF / QEMU died" if (pump.eof or proc.poll() is not None)
                   else f"timeout after {timeout:.0f}s")
            record(f"{tag}: '{needle.decode()}'", False, why)
            return False, proc, sock, pump, logf, -1
        now = time.monotonic()
        record(f"{tag}: '{needle.decode()}'", True, f"{now - t_prev:.1f}s")
        t_prev = now
        pos = idx + len(needle)
    return True, proc, sock, pump, logf, pos


def inject_lines(tag, proc, sock, pump, lines, label):
    """Send (line, settle_s) pairs down the serial console. False on send error."""
    for item in lines:
        cmd, settle = (item, CMD_GAP_S) if isinstance(item, str) else item
        try:
            sock.sendall(cmd.encode() + b"\n")
        except OSError as exc:
            record(f"{tag}: {label} '{cmd}'", False, f"send failed: {exc}")
            return False
        pump.drain_for(settle)
    return True


def liveness_record(tag, proc, pump, pos, name):
    alive = proc.poll() is None and not pump.eof
    crash = pump.has_crash_since(pos)
    record(name, alive and crash is None,
           "qemu alive, serial clean" if (alive and crash is None)
           else f"alive={alive} crash={crash}")


def run_battery(tag, proc, sock, pump, session_pos):
    """Inject the standard shell command battery, then assert nothing crashed."""
    if inject_lines(tag, proc, sock, pump, BATTERY, "battery"):
        record(f"{tag}: command battery injected", True,
               f"{len(BATTERY)} commands via serial")
    liveness_record(tag, proc, pump, session_pos,
                    f"{tag}: still alive, no panic/exception")


def check_storage(tag, pump, with_disk):
    """Storage-mode assertion. The mount is lazy (first VFS access — the
    standard battery's `ls /` forces it), so this runs after that battery and
    searches the whole serial capture, not just the boot log."""
    buf = bytes(pump.buf)
    online = buf.find(STORAGE_ONLINE) >= 0
    alt = next((a for a in STORAGE_ONLINE_ALTS if buf.find(a) >= 0), None)
    ram_only = buf.find(STORAGE_RAM_ONLY) >= 0
    # Quote the actual [disk] line for diagnostics.
    disk_line = ""
    at = buf.rfind(b"[disk]")
    if at >= 0:
        end = buf.find(b"\n", at)
        disk_line = buf[at:end if end >= 0 else len(buf)].decode(errors="replace").strip()

    if with_disk:
        if online:
            record(f"{tag}: storage 'persistent storage online' (--with-disk)", True,
                   disk_line)
        elif alt is not None and not ram_only:
            record(f"{tag}: storage 'persistent storage online' (--with-disk)", True,
                   f"image was blank: '{alt.decode()}' counts as online (write-through live)")
        else:
            record(f"{tag}: storage 'persistent storage online' (--with-disk)", False,
                   f"RAM-only outcome or no storage line — got: {disk_line or '<none>'}")
    else:
        matched = (b"persistent storage online" if online else
                   alt if alt is not None else
                   STORAGE_RAM_ONLY if ram_only else None)
        record(f"{tag}: storage mode reported ('persistent storage online' or 'RAM-only')",
               matched is not None,
               f"got: {disk_line}" if matched is not None
               else "no [disk] line at all — lazy mount never ran?")


def run_stress_battery(tag, proc, sock, pump, session_pos):
    """The stress battery, then TOP-mode quit and a shell-responsiveness probe."""
    if inject_lines(tag, proc, sock, pump, STRESS_BATTERY, "stress"):
        try:
            # STRESS_BATTERY's last line is `top`; a bare 'q' leaves TOP mode.
            sock.sendall(b"q")
            pump.drain_for(TOP_QUIT_SETTLE_S)
            sock.sendall(b"\n")  # clear a stray 'q' at the prompt if top never entered
            pump.drain_for(1.0)
            sock.sendall(b"uptime\n")  # shell responsive again?
            pump.drain_for(CMD_GAP_S)
        except OSError as exc:
            record(f"{tag}: stress battery", False, f"send failed: {exc}")
            return
        record(f"{tag}: stress battery injected", True,
               f"{len(STRESS_BATTERY)} lines + TOP-mode q + uptime probe")
    liveness_record(tag, proc, pump, session_pos,
                    f"{tag}: still alive after stress, no panic/exception")


def run_soak(tag, proc, sock, pump, seconds):
    """Seeded-random command + key-byte injection for `seconds`, liveness only."""
    rng = random.Random(SOAK_SEED)
    t0 = time.monotonic()
    deadline = t0 + seconds
    n_cmds = 0
    n_keys = 0
    next_note = t0 + 15.0
    soak_pos = len(pump.buf)
    ok = True
    detail = ""
    while time.monotonic() < deadline:
        if proc.poll() is not None or pump.eof:
            ok, detail = False, "QEMU died / serial EOF during soak"
            break
        crash = pump.has_crash_since(soak_pos)
        if crash is not None:
            ok, detail = False, crash
            break
        try:
            if rng.random() < 0.7:
                sock.sendall(rng.choice(SOAK_COMMANDS).encode() + b"\n")
                n_cmds += 1
            else:
                sock.sendall(rng.choice(SOAK_KEYS))
                n_keys += 1
        except OSError as exc:
            ok, detail = False, f"send failed: {exc}"
            break
        pump.drain_for(rng.uniform(0.3, 1.0))
        if time.monotonic() >= next_note:
            remaining = max(0.0, deadline - time.monotonic())
            print(f"[info] soak: {n_cmds} commands, {n_keys} key bursts, "
                  f"{remaining:.0f}s left", flush=True)
            next_note += 15.0
    if ok:
        try:
            sock.sendall(b"uptime\n")  # final liveness probe
            pump.drain_for(3.0)
        except OSError as exc:
            ok, detail = False, f"final uptime send failed: {exc}"
    if ok:
        alive = proc.poll() is None and not pump.eof
        crash = pump.has_crash_since(soak_pos)
        ok = alive and crash is None
        detail = ("qemu alive, serial clean" if ok
                  else f"alive={alive} crash={crash}")
    record(f"{tag}: soak {seconds:.0f}s survived", ok,
           f"{n_cmds} commands, {n_keys} key bursts — {detail}")


# --------------------------------------------------------------------------
# cocoa screenshot pass
# --------------------------------------------------------------------------

def find_qemu_window(timeout=90.0):
    """Window number of our smoketest QEMU's cocoa window (via CGWindowList)."""
    deadline = time.monotonic() + timeout
    fallback = None
    while time.monotonic() < deadline:
        try:
            out = subprocess.run(["xcrun", "swift", "-"], input=WINDOW_FINDER_SWIFT,
                                 capture_output=True, text=True, timeout=180)
            for line in out.stdout.splitlines():
                parts = line.split("\t")
                if len(parts) < 3:
                    continue
                num, owner, name = parts[0], parts[1], parts[2]
                if not num.isdigit():
                    continue
                if "smoketest" in name.lower():
                    return int(num), f"owner={owner} name={name!r}"
                if fallback is None:
                    fallback = (int(num), f"owner={owner} name={name!r} (not our title, guessing)")
        except (subprocess.SubprocessError, OSError):
            pass
        time.sleep(2.0)
    if fallback is not None:
        return fallback
    return None, "no qemu window found (Screen Recording permission? window off-screen?)"


def screencapture_window(win_id, path):
    proc = subprocess.run(["screencapture", "-x", "-o", "-l", str(win_id), path],
                          capture_output=True, text=True)
    ok = (proc.returncode == 0 and os.path.exists(path)
          and os.path.getsize(path) > 1024)
    return ok, (proc.stderr or proc.stdout).strip()


# ---- tiny pure-python PNG reader (8-bit RGB/RGBA, non-interlaced) ---------

PNG_SIG = b"\x89PNG\r\n\x1a\n"


def read_png(path):
    """Returns (width, height, bytesPerPixel, raw scanline bytes with filter bytes)."""
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(PNG_SIG):
        raise ValueError("not a PNG file")
    pos = len(PNG_SIG)
    width = height = bitdepth = colortype = interlace = None
    idat = bytearray()
    while pos + 8 <= len(data):
        length, ctype = struct.unpack_from(">I4s", data, pos)
        pos += 8
        chunk = data[pos:pos + length]
        pos += length + 4  # payload + CRC
        if ctype == b"IHDR":
            (width, height, bitdepth, colortype,
             _comp, _filt, interlace) = struct.unpack(">IIBBBBB", chunk)
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break
    if bitdepth != 8 or colortype not in (2, 6) or interlace != 0:
        raise ValueError(f"unsupported PNG: bitdepth={bitdepth} colortype={colortype} "
                         f"interlace={interlace} (need 8-bit RGB/RGBA non-interlaced)")
    return width, height, (3 if colortype == 2 else 4), zlib.decompress(bytes(idat))


def unfilter_row(ftype, cur, prev, bpp):
    n = len(cur)
    if ftype == 0:
        return
    if ftype == 1:    # Sub
        for i in range(bpp, n):
            cur[i] = (cur[i] + cur[i - bpp]) & 0xFF
    elif ftype == 2:  # Up
        for i in range(n):
            cur[i] = (cur[i] + prev[i]) & 0xFF
    elif ftype == 3:  # Average
        for i in range(n):
            a = cur[i - bpp] if i >= bpp else 0
            cur[i] = (cur[i] + ((a + prev[i]) >> 1)) & 0xFF
    elif ftype == 4:  # Paeth
        for i in range(n):
            a = cur[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            cur[i] = (cur[i] + pr) & 0xFF
    else:
        raise ValueError(f"unknown PNG filter type {ftype}")


def row_color_match(row, width, bpp, rgb, tol, stride):
    """True when >=50% of sampled OPAQUE pixels are within tol of rgb."""
    hits = total = 0
    for x in range(0, width, stride):
        i = x * bpp
        if bpp == 4 and row[i + 3] < 128:
            continue  # transparent capture border (rounded window corners)
        if (abs(row[i] - rgb[0]) <= tol and abs(row[i + 1] - rgb[1]) <= tol
                and abs(row[i + 2] - rgb[2]) <= tol):
            hits += 1
        total += 1
    return total > 0 and hits * 2 >= total


def find_color_in_row(row, width, bpp, rgb):
    """First opaque pixel within TERM_TOL of rgb; exact aligned match tried
    first (C-speed bytes.find). Returns (x, exact) or (None, False)."""
    target = bytes(rgb)
    i = row.find(target)
    while i != -1:
        if i % bpp == 0 and (bpp == 3 or row[i + 3] >= 128):
            return i // bpp, True
        i = row.find(target, i + 1)
    for x in range(0, width, 2):
        j = x * bpp
        if bpp == 4 and row[j + 3] < 128:
            continue
        if (abs(row[j] - rgb[0]) <= TERM_TOL and abs(row[j + 1] - rgb[1]) <= TERM_TOL
                and abs(row[j + 2] - rgb[2]) <= TERM_TOL):
            return x, False
    return None, False


def analyze_screenshot(path):
    """Streams scanlines once. Returns:
       (w, h, panel, term) where
       panel = (top_row, matching_rows_in_next_32) or None — the desktop panel
               is the FIRST panel-colored row band in the capture (the macOS
               title bar above it never matches); the panel's 1px bottom
               separator doesn't match, hence a match count, not a run length.
       term  = (x, first_y, exact) or None — terminal background must appear
               on >= TERM_MIN_ROWS distinct rows so 1px hairlines don't count.
    """
    w, h, bpp, raw = read_png(path)
    rowlen = w * bpp
    prev = bytearray(rowlen)
    stride = max(1, w // 320)
    panel_top = None
    panel_match = 0
    term_hit = None
    term_rows = set()
    off = 0
    for y in range(h):
        cur = bytearray(raw[off + 1: off + 1 + rowlen])
        unfilter_row(raw[off], cur, prev, bpp)
        off += 1 + rowlen
        prev = cur
        if panel_top is None:
            if row_color_match(cur, w, bpp, PANEL_RGB, PANEL_TOL, stride):
                panel_top = y
                panel_match = 1
        elif y < panel_top + PANEL_WINDOW:
            if row_color_match(cur, w, bpp, PANEL_RGB, PANEL_TOL, stride):
                panel_match += 1
        if len(term_rows) < TERM_MIN_ROWS:
            x, exact = find_color_in_row(cur, w, bpp, TERM_RGB)
            if x is not None:
                term_rows.add(y)
                if term_hit is None:
                    term_hit = (x, y, exact)
        panel_done = panel_top is not None and y >= panel_top + PANEL_WINDOW - 1
        if panel_done and len(term_rows) >= TERM_MIN_ROWS:
            break
    panel = (panel_top, panel_match) if panel_top is not None else None
    if len(term_rows) < TERM_MIN_ROWS:
        term_hit = None
    return w, h, panel, term_hit


def check_screenshot(tag, path):
    try:
        w, h, panel, term = analyze_screenshot(path)
    except (ValueError, zlib.error, OSError) as exc:
        record(f"{tag}: pixels {os.path.basename(path)}", False, str(exc))
        return
    # "Top 32 rows contain the panel color": screencapture -l includes the
    # macOS title bar, so the guest's top 32 rows (= the 32px panel) start
    # below it — anywhere in the top eighth of the capture counts as "top".
    name = os.path.basename(path)
    if panel is not None and panel[0] <= h // 8 and panel[1] >= PANEL_MIN_MATCH:
        record(f"{tag}: panel #191C21±{PANEL_TOL} in top {PANEL_WINDOW} rows ({name})",
               True, f"{w}x{h}, guest panel at rows {panel[0]}..{panel[0] + PANEL_WINDOW - 1} "
                     f"({panel[1]}/{PANEL_WINDOW} rows match)")
    else:
        record(f"{tag}: panel #191C21±{PANEL_TOL} in top {PANEL_WINDOW} rows ({name})",
               False, f"{w}x{h}, panel={panel} — need >= {PANEL_MIN_MATCH}/{PANEL_WINDOW} "
                      f"matching rows starting in top {h // 8} rows")
    if term is not None:
        x, y, exact = term
        record(f"{tag}: terminal bg #0D0F13 present ({name})", True,
               f"first at ({x},{y}), >= {TERM_MIN_ROWS} rows"
               f"{'' if exact else f' (±{TERM_TOL})'}")
    else:
        record(f"{tag}: terminal bg #0D0F13 present ({name})", False,
               f"not found on >= {TERM_MIN_ROWS} rows")


def cocoa_pass(keep, with_disk=False):
    tag = "cocoa"
    ok, proc, sock, pump, logf, session_pos = boot_pass(
        tag, "cocoa", SOCK_COCOA, extra_args=["-name", "SwiftOS-smoketest"],
        with_disk=with_disk)
    try:
        if not ok:
            return
        print(f"[info] cocoa pass: settling {SPLASH_SETTLE_S:.0f}s for boot splash",
              flush=True)
        pump.drain_for(SPLASH_SETTLE_S)

        os.makedirs(SHOTS_DIR, exist_ok=True)
        win_id, detail = find_qemu_window()
        record(f"{tag}: qemu window found", win_id is not None, detail)
        if win_id is None:
            return

        shot1 = os.path.join(SHOTS_DIR, "shot-1-desktop.png")
        ok1, err1 = screencapture_window(win_id, shot1)
        record(f"{tag}: screenshot {os.path.relpath(shot1, ROOT)}", ok1, err1)

        run_battery(tag, proc, sock, pump, session_pos)
        check_storage(tag, pump, with_disk)
        pump.drain_for(POST_BATTERY_SETTLE_S)  # let neofetch finish drawing

        shot2 = os.path.join(SHOTS_DIR, "shot-2-battery.png")
        ok2, err2 = screencapture_window(win_id, shot2)
        record(f"{tag}: screenshot {os.path.relpath(shot2, ROOT)}", ok2, err2)

        if ok1:
            check_screenshot(tag, shot1)
        if ok2:
            check_screenshot(tag, shot2)

        # Same stress battery as the headless pass: heavy text output
        # (tree /, find /, cat syslog) exercises the GUI renderer, not just
        # the input path.
        run_stress_battery(tag, proc, sock, pump, session_pos)
        liveness_record(tag, proc, pump, 0,
                        f"{tag}: no crash markers (whole run)")
    finally:
        save_serial(tag, pump)
        stop_qemu(proc, sock, logf, keep)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="SwiftOS smoke test (build + boot + batteries + optional soak)")
    ap.add_argument("--cocoa", action="store_true",
                    help="second pass with -display cocoa: window screenshots into "
                         "build/smoke-shots/ + pixel assertions")
    ap.add_argument("--with-disk", action="store_true",
                    help="attach a snapshot of build/disk.img (build/smoke-disk.img) "
                         "and REQUIRE persistent storage to come online (RAM-only fails)")
    ap.add_argument("--soak", type=float, default=0.0, metavar="SECONDS",
                    help="after the batteries: seeded-random command/key injection "
                         "for SECONDS with liveness assertions, then a final 'uptime'")
    ap.add_argument("--keep-qemu", action="store_true",
                    help="leave the LAST pass's QEMU running")
    args = ap.parse_args()

    t0 = time.monotonic()
    print("== SwiftOS smoke test ==", flush=True)

    if shutil.which(QEMU) is None:
        record("env: qemu-system-aarch64 on PATH", False, "not found")
    elif not os.path.exists(SWIFTC):
        record("env: swiftc toolchain", False, SWIFTC)
    elif not step_make():
        pass
    elif args.with_disk and not snapshot_disk():
        pass
    else:
        # --- headless pass -------------------------------------------------
        ok, proc, sock, pump, logf, session_pos = boot_pass(
            "boot", "none", SOCK_HEADLESS, with_disk=args.with_disk)
        try:
            if ok:
                print(f"[info] settling {SPLASH_SETTLE_S:.0f}s for boot splash", flush=True)
                pump.drain_for(SPLASH_SETTLE_S)
                run_battery("boot", proc, sock, pump, session_pos)
                check_storage("boot", pump, args.with_disk)
                run_stress_battery("boot", proc, sock, pump, session_pos)
                if args.soak > 0:
                    run_soak("boot", proc, sock, pump, args.soak)
                # Negative assertions across the WHOLE run, boot byte 0 on.
                liveness_record("boot", proc, pump, 0,
                                "boot: no crash markers (whole run)")
        finally:
            save_serial("boot", pump)
            # With --cocoa a second instance follows; keeping both is confusing,
            # so --keep-qemu only ever keeps the last pass alive.
            stop_qemu(proc, sock, logf, keep=args.keep_qemu and not args.cocoa)

        # --- cocoa pass ----------------------------------------------------
        if args.cocoa:
            if ok:
                cocoa_pass(keep=args.keep_qemu, with_disk=args.with_disk)
            else:
                record("cocoa: pass", False, "skipped — headless boot failed")

    n_pass = sum(1 for _, ok, _ in results if ok)
    n_fail = sum(1 for _, ok, _ in results if not ok)
    elapsed = time.monotonic() - t0
    print(f"== SMOKE {'PASS' if n_fail == 0 else 'FAIL'}: "
          f"{n_pass} passed, {n_fail} failed, {elapsed:.1f}s ==", flush=True)
    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
