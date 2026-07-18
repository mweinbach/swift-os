# SwiftOS

A real operating system written **entirely in Swift** — a bare-metal aarch64
kernel (Embedded Swift, no stdlib runtime) with a Linux-feel GUI desktop
running on top. Boots on QEMU's `virt` machine configured to match a
**Raspberry Pi 5 (8 GB)**: Cortex-A76, 4 cores, 8 GiB RAM. No Linux, and in
the kernel/userland no Apple frameworks at all: every driver, the scheduler,
the filesystem, the window manager, the shell, and the renderer are our own
Swift.

```
SwiftOS kernel 1.0.0-aarch64 (Embedded Swift, bare metal)
[boot] exception level EL1
[boot] heap 248 MB
[boot] heap self-test ok
[mmu] identity map on, caches enabled
[gic] timer irq 30 at 100 Hz
[fb] ramfb 1280x800 @ 0x0000000044804000
[blk] virtio-blk (slot 29): 65536 sectors (32 MiB)
[disk] persistent storage online
[sched] scheduler up: main + idle + kworker, quantum 50 ms
[input] virtio tablet (slot 30)
[input] virtio keyboard (slot 31)
[boot] login session started — compositor running
```

## Features

**Kernel**
- **Device-tree machine discovery** (FDT parser): RAM size, CPUs, GIC, UART,
  fw_cfg, virtio-mmio slots, PSCI method — no hardcoded platform addresses
- Boot at EL2→EL1, FP/SIMD bring-up on all 4 cores, PL011 UART console
- **Real SMP**: all 4 cores schedule threads off a global run queue
  (baton-locked context switch, per-core 100 Hz ticks and idles, cross-core
  kill/reap, Linux-style %CPU — `smpdemo 3` shows ~300% across cores)
- Panic broadcast: any core's panic halts the others via IPI
- MMU + caches identity-mapping the full **8 GiB**, 1 GiB kernel heap
- MMU + caches (identity map), page-bitmap physical allocator + boundary-tag
  heap backing the Swift runtime's `posix_memalign`/`free`
- GICv2 + ARM generic timer (100 Hz tick), full exception vector table
- **Preemptive round-robin kernel threads** (50 ms quantum, context switch in
  the timer IRQ) with real per-thread CPU accounting
- **Scheduled EL0 user processes** (`urun`): real user-mode threads with
  per-process L2/L3 page tables, SVC syscall ABI, preemption and migration
  across cores (per-core page-table pairs + switch-time TLB flush),
  containment on faults, kill/reap with full teardown
- **virtio-blk storage** + **SwiftFS**, our own filesystem — now with a
  **metadata journal** (sector-level redo log, mount-time replay): verified
  consistent after SIGKILL mid-write, three cycles
- **Networking**: virtio-net driver + ethernet/ARP/IPv4/ICMP/**UDP** stack —
  `ping` gets real echo replies, **`nslookup`/`host` resolve real names via
  DNS** (QEMU slirp), and the kernel answers pings addressed to it
- **Power**: PSCI shutdown/reboot (`shutdown` powers the VM off for real)
- fw_cfg/**ramfb** 1280×800 display, double-buffered, software-composited
- **virtio-mmio** keyboard + tablet (absolute mouse), plus serial input

**Userland (all running on the kernel)**
- Window manager (drag/resize/minimize/maximize/focus), desktop environment
  (boot splash fed by the real kernel log, panel, taskbar, icons, context menu)
- Terminal emulator (scrollback, history, tab completion, **ANSI SGR colors**)
- `swish` shell: ~35 commands (`ls`, `cat`, `grep`, `ps`, `kill`, `ping`,
  `tree`, `du`, `mv`, `neofetch`, `nano`, `top`, `open`, `shutdown`…),
  pipes, `>`/`>>` redirection, `~`/`$VAR` expansion
- Interactive **htop-style `top`** mode inside the terminal (live process
  table, `q` quits)
- In-memory-or-persistent Linux-like VFS (`typed throws(VFSError)`)
- Apps: file manager, text editor (soft-wrap, save), htop-style system monitor
  reading **real** kernel data (tasks, CPU%, allocator, uptime, load)
- Software rasterizer (paired-pixel fills, glyph-run text) with a
  build-time-generated 8×16 Menlo bitmap font
- Shortcuts: Ctrl+Alt+T new terminal, Ctrl+Alt+W close window, **Alt+drag**
  move / Alt+right-drag resize windows (Metacity-style), right-click desktop
  menu, panel power menu

## Quickstart

Requirements: macOS on Apple Silicon, QEMU (`brew install qemu`), and the
Swift 6.2 toolchain (the Makefile pins `~/Library/Developer/Toolchains/
swift-6.2-RELEASE.xctoolchain` + `~/.swiftly/bin/ld.lld`).

```sh
make            # build build/swiftos.elf
make run        # boot it: QEMU virt, cocoa window, disk attached
```

Wait for the boot splash (~10 s wall under TCG), then click around or type.
The terminal is focused at login — try `neofetch`, `ls /etc`, `ps aux`,
`open .`, `nano notes.txt`.

```sh
make serial                 # headless boot, serial on stdio
python3 tools/smoketest.py  # regression gate: build + boot + battery (+ --cocoa)
make font                   # regenerate the bitmap font (uses macOS CoreText)
make app                    # build the Host-macOS Metal dev-harness
make disk                   # (re)create the 32 MB build/disk.img
```

Files written inside the OS persist on `build/disk.img` between boots
(delete it to factory-reset).

## Architecture

```
┌────────────────────────── Userland (embedded Swift) ───────────────────────┐
│ WindowManager / Desktop / Terminal / swish / VFS / Files / Editor / Monitor │
│ Surface (draw API) ─ SoftwareSurface rasterizer ─ Menlo bitmap font        │
├──────────────────────────── Kernel ────────────────────────────────────────┤
│ Scheduler (preemptive threads)  Tasks+CPU accounting   KernelServices seam  │
│ GIC+timer IRQs   MMU+caches   page-bitmap heap (posix_memalign/free)       │
│ Drivers: PL011 UART · ramfb (fw_cfg) · virtio-input · virtio-blk · SwiftFS │
│ Boot.S (EL2→EL1, FP/SIMD, BSS)        libc/runtime shims (Support.swift)   │
└───────────────────────────── QEMU virt (aarch64) ──────────────────────────┘
```

- `Kernel/` — kernel sources (+ `Boot.S`, `Vectors.S`, `Scheduler.S`, `MMU.S`)
- `Userland/` — everything above the kernel, compiled into the same module
- `tools/` — `genfont.swift` (font generator), `smoketest.py` (regressions)
- `Host-macOS/` — the earlier Metal/AppKit dev-harness (secondary)
- `Makefile`, `link.ld`, `AGENTS.md` (deep contributor notes)

Everything in `Kernel/` and `Userland/` follows Embedded Swift rules: no
Foundation/CoreGraphics, no protocol existentials (`Surface`/`OSApp` are base
classes), typed throws only, no `Date`/`String(format:)` — see `AGENTS.md`
for the full rule set and the hard-won platform gotchas (FP/SIMD trap, MMU
alignment faults, unicode shims, QEMU quirks).

## Current limitations

- Targets QEMU `virt` (Pi 5 profile: A76, 4 cores, 8 GiB); real-hardware
  bring-up is future work
- Userland and drivers run on cpu0 by design; EL0 user processes and
  cross-core TLB shootdown are future work
- Apps share the compositor thread (kernel threads are preemptive; EL0 is a
  single synchronous demo run, not yet scheduled user processes)
- Networking is IPv4+ICMP so far — no TCP/UDP yet
- Unicode support is ASCII-correct; shell has `;` but not `&&`
- TCG emulation speed, not the kernel, limits frame rate

## Roadmap ideas

Scheduled EL0 user processes with per-process page tables · UDP/TCP ·
real-hardware device tree · SMP
