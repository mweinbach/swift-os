# SwiftOS

A real operating system written entirely in Swift: a bare-metal aarch64 kernel
(Embedded Swift) with a Linux-feel GUI desktop — window manager, terminal,
shell, file manager, text editor, system monitor — running on top. Boots on
QEMU's `virt` machine. No Linux, and in the kernel/userland no Apple
frameworks at all (no Foundation/CoreGraphics/AppKit/Metal).

Machine profile: **Raspberry Pi 5 match** — QEMU has no raspi5 machine model
(and raspi3b/raspi4b use an incompatible BCM peripheral map), so we run
`-M virt -cpu cortex-a76 -smp 4 -m 8192`: same Cortex-A76 cores, core count,
and 8 GiB RAM. The MMU identity-maps 8 GiB (L1[1..8] -> per-GiB L2 tables);
the kernel heap is 1 GiB at 0x40800000-0x80800000. SMP: secondaries come
online via PSCI CPU_ON (per-core FP/SIMD enable), REPLAY the BSP's captured
MMU sysregs (PSCI starts them MMU-off — memory is device-like and unaligned
accesses fault), run Interrupts.initCoreInterrupts (banked GIC CPU interface
+ SGI/PPI enables, vectors, local 100 Hz tick), and enter
Scheduler.runCore(cpu:) — per-core scheduling is live. Real spinlocks +
lock hierarchy in Kernel/Locks.swift (sched/tasks > klog > heap). SGI 1 is
the panic-halt IPI: the panic path broadcasts it first thing (target-list
mode via GICD_SGIR), other cores park silently in wfi, and the dump takes
NO locks at all.

## Layout

- `Kernel/` — the kernel: `Boot.S` (entry, EL2→EL1 drop, BSS, FP/SIMD enable,
  asm helpers), `Main.swift` (kmain + compositor loop), `UART.swift` (PL011 +
  klog/kprint + BootLog), `MMIO.swift` (volatile accessors), `Interrupts.swift`
  + `Vectors.S` (GICv2 + 100 Hz per-core timer ticks; `initCoreInterrupts(cpu:)`
  is the per-core GICC/banked-PPI/vectors/tick bring-up every core runs; SGI 1
  is the panic-halt IPI, parked inline by irq_entry; the fatal sync/FIQ/SError
  vector stubs snapshot all GPRs and call `swift_fatal_exception`), `Panic.swift`
  (crash dump: first broadcasts SGI 1 to park all other cores, then full
  register/ESR/FAR dump + frame-pointer backtrace on serial, then
  the same text rendered onto the front framebuffer — zero allocation,
  StaticString-only, NO locks of any kind, recursive-fault guard;
  serial-only when `Display.width`
  is 0), `SMP.swift` + `SMP.S` (PSCI CPU_ON bring-up, the per-core MMU join
  that replays the BSP's captured translation sysregs, `arm_read_mpidr`, the
  klog spinlock), `Locks.swift` (cross-core spinlock hierarchy:
  sched/tasks > klog > heap), `Heap.swift` (page bitmap + boundary-tag
  malloc backing `posix_memalign`/`free`; header/footer words carry a 32-bit
  magic — 0xA110CA7E allocated / 0xFEE1DEAD freed — bad frees are logged on
  the UART and ignored, never panicking or corrupting; `validate()` is an
  allocation-free deep audit callable from kworker; heap diagnostics use
  literal-only UART writes because klog allocates via BootLog), `MMU.swift` + `MMU.S` (identity map,
  caches), `RamFB.swift` (`Display`: fw_cfg/ramfb 1280x800 + back buffer +
  present), `VirtioInput.swift` (`Input`: virtio-mmio legacy keyboard/tablet +
  UART serial keys → `OSEvent`), `VirtioBlk.swift` (`BlockDev`: virtio-mmio
  legacy block device, synchronous polled 512B sector I/O), `SwiftFS.swift`
  (our own simple persistent filesystem on BlockDev: superblock + 256 inodes
  + block bitmap, 4 KiB contiguous spans, write-through, plus a 64-sector
  metadata journal — sector-level physical redo: every inode/bitmap sector
  goes to the journal first (payload → header → commit marker), then to its
  real location; mount replays committed-but-unapplied records; all file
  content writes are copy-on-write with a single journaled inode flip, so a
  power cut leaves every file fully old or fully new. Legacy pre-journal
  images mount in journaled-off mode, logged; new formats get the journal —
  superblock +44/+48 journalStart/journalSectors, magic still SWFS0001), `Tasks.swift` (task
  registry/CPU accounting), `Power.swift` + `PSCI.S` (PSCI 0.2 SYSTEM_OFF /
  SYSTEM_RESET over `hvc #0` — QEMU virt has no EL3 by default, so the DTB
  conduit is HVC, not SMC; QEMU exits 0 on shutdown, and on reset when
  started with `-no-reboot`), `Userspace.swift` + `Userspace.S` (EL0 userspace:
  the legacy synchronous `runDemo()` blob run (identity-mapped pages,
  unchanged) AND scheduled user processes — `UserProcess.spawn(blob:)`
  starts the blob as a real preemptible EL0 thread (`user<N>` in ps/top,
  killable via `UserProcess.kill(pid:)`, migratable, SMP-concurrent), with
  per-process L2/L3 maps installed in the running core's private L1
  `userSlot` (9) by the scheduler's switch hook; the shared `svc #0` ABI —
  0=write(fd 1, captured + UART mirror) 1=uptime_ms 2=exit 3=yield; exit
  and faults terminate the thread via `Scheduler.exit()` from the sync
  handler (contained, never a panic); gated by `Config.enableUserland`;
  lower-EL vector rows in `Vectors.S` route SVCs and EL0-preempting IRQs),
  `KernelServices.swift` (the `Platform.services`
  seam), `Support.swift` (libc/runtime shims), `Config.swift` (compiled-in
  fallback machine values), `DTB.swift` (`Machine`: FDT parser + machine
  discovery — RAM size, cpu count, GIC/UART/fw-cfg bases, virtio-mmio
  slots, psci method from the device tree QEMU leaves at the RAM base;
  every field defaults to the old hardcoded value on any parse failure).
  Drivers read `Machine.*`, never fresh hardcoded addresses.
- `Userland/` — software compiled into the same module: `Geometry.swift`
  (Point/Size/Rect/Color, `CGFloat=Double`, CGRect aliases), `Events.swift`,
  `Surface.swift` (draw API **base class**), `Rasterizer.swift`
  (`SoftwareSurface`: software renderer + alpha + clip + text),
  `FontData.swift` (generated 8x16 Menlo bitmap), `TimeFmt.swift` (TimeFmt +
  NumFmt — no Foundation formatting), `Services.swift` (ProcessInfo +
  `Platform.services`), `WindowManager.swift` (`OSApp` **base class**, OSWindow,
  WindowManager), `Desktop.swift`, `Terminal.swift`, `Shell.swift`, `VFS.swift`
  (in-memory Linux-like tree, typed throws; persists to SwiftFS when a disk
  is attached — `Disk.initAndMount()`, lazy on first VFS access),
  `FileManagerApp.swift`, `TextEditorApp.swift`, `SystemMonitorApp.swift`,
  `UserBlob.swift` (generated EL0 demo program bytes — see tools/mkblob.py).
- `tools/genfont.swift` — macOS/CoreText generator that produces FontData.swift.
- `tools/mkblob.py` — assembles `User/demo.S` (pure position-independent EL0
  demo, `svc #0` ABI) and links it flat at address 0 into `Userland/UserBlob.swift`.
- `tools/smoketest.py` — regression harness: builds, boots headless (with
  virtio-net attached), asserts the ordered boot log (heap → gic → sched →
  fb → input → net → login), injects the standard + stress shell batteries
  (storage-mode check, ping/udemo/tree/du/find, TOP-mode entry/exit), and
  scans the whole run for panic/heap-fault markers. Flags: `--cocoa`
  (screenshot pixel checks), `--with-disk` (mounts a snapshot of
  build/disk.img, requires persistent storage online), `--soak N`
  (seeded-random command/key injection for N seconds), `--keep-qemu`.
- `tools/fsck_swiftfs.py` — offline SwiftFS checker: parses superblock/inode
  table/bitmap/journal, validates structure (parent links, reachability,
  span overlap, bitmap cross-check — used-but-unreferenced blocks are
  crash-window leaks, warnings only), and with `--expect ops.json` verifies
  a known write burst: every file fully present with exact contents or fully
  absent, executed ops form a prefix of sent ops.
- `tools/journaltest.py` — SwiftFS journal fault-injection gate: boots QEMU,
  injects a deterministic write/mkdir/mv burst, SIGKILLs mid-burst, offline
  fsck, reboots, asserts journal replay + fsck again (3 cycles + legacy-image
  phase). `--elf/--workdir` point at scratch builds.
- `Host-macOS/` — the earlier macOS SwiftPM harness (Metal/AppKit app showing
  the same desktop). Secondary; the kernel is the product. (Renderer note:
  CTFontDrawGlyphs already draws upright with bitmap row 0 = visual top —
  do NOT add a CTM flip, that double-flips every glyph.)
- `Makefile`, `link.ld` — kernel build.

## Build & run

```sh
make            # builds build/swiftos.elf (swiftly Swift 6.2, Embedded Swift)
make run        # QEMU virt + ramfb + virtio input + virtio-blk disk + cocoa
make serial     # headless, serial on stdio
make disk       # create the 32MB build/disk.img (run/serial depend on it)
make font       # regenerate Userland/FontData.swift (needs macOS CoreText)
python3 tools/mkblob.py   # regenerate Userland/UserBlob.swift from User/demo.S
make app        # build the Host-macOS harness
python3 tools/smoketest.py [--cocoa] [--with-disk] [--soak N]   # regression gate: boot + batteries + pixels
```

Round-2 features: preemptive kernel threads (main/idle/kworker with real
per-thread CPU% in `ps`), persistent SwiftFS storage (two-boot verified),
ANSI SGR colors in the terminal (colored ls/errors/grep), `kill`/`nano`/`top`,
Ctrl+Alt+T opens a terminal / Ctrl+Alt+W closes a window / right-click desktop
menu, and compositor frame skipping (idle desktop presents ~2 Hz; interactive
frames draw immediately).

Round-6 user processes: `urun` spawns the embedded blob as a SCHEDULED EL0
user process (`user<N>` in ps/top, preemptible on any core, several at EL0
simultaneously on different cores), `ukill <pid>` terminates it (pages, map
and stack all freed); `udemo` still runs the same blob synchronously (short
legacy mode — the blob picks long/short behaviour from the x0 run-mode
argument). See the MMU hard-won note for the per-core L1[userSlot] design
and the SP_EL0 save/restore rule.

Toolchain pins: swiftc from `~/Library/Developer/Toolchains/swift-6.2-RELEASE.xctoolchain`,
lld from `~/.swiftly/bin/ld.lld`, clang via `xcrun clang`. **Do not** use plain
`swift build` for the macOS harness — the swiftly toolchain hangs compiling
macOS SDK modules on this machine; use `xcrun swift build` inside Host-macOS/.

### Automated testing through the serial socket

Boot with `-serial unix:build/ser.sock,server=on,wait=off` and inject keys
from python (`s.send(b'neofetch\n')`) — the UART driver turns bytes into key
events (bare LF and CR both count as Return; ESC[... sequences map arrows).
The UART text output comes back on the same socket. QEMU windows can be
captured by window id via `screencapture -x -l <id>`; add `-d int -D build/qemu-dbg.log`
to see exceptions (ESR 0x1fe00000 = FP/SIMD trap, 0x960000xx = data abort).

### Persistent disk (SwiftFS)

Attach a raw image and the VFS persists across boots (blank images are
formatted and seeded automatically; without a disk the VFS stays RAM-only):

```sh
dd if=/dev/zero of=build/disk.img bs=1m count=32   # one time
# add to QEMU: -drive file=build/disk.img,format=raw,if=none,id=hd0 \
#              -device virtio-blk-device,drive=hd0
```

`/var/log/syslog` is the one path never persisted (always rendered live from
the boot log). `make run`/`make serial` attach the disk automatically; a fresh
blank image is formatted + seeded on first boot. Boot serial testing tip:
`wait=on` on the unix serial socket
holds the guest until your client connects — with `wait=off` the whole boot
log is emitted before you can attach and is silently dropped; and the boot
splash eats keystrokes for ~12 s wall after "login session started".

## Embedded Swift rules (this codebase runs without a stdlib runtime)

- Stdlib only. **Never** import Foundation/CoreGraphics/AppKit/Metal/Dispatch
  in Kernel/ or Userland/.
- **No protocol existentials** — `any P` does not compile. `Surface` and
  `OSApp` are base *classes*; subclass and `override`.
- **Typed throws only**: `throws(VFSError)`; untyped `throws` needs `any Error`.
- No Date/DateFormatter/UUID/Locale/regex/String(format:)/print. Use
  `Platform.services.wallClockMs`, `TimeFmt.*`, `NumFmt.*`, klog/kprint.
- IRQ context: no allocations, counters + MMIO only.
- `KernelHeap` code itself must never allocate (it backs posix_memalign).

## Hard-won platform notes (do not rediscover these)

- **FP/SIMD must be enabled in boot** (CPACR_EL1.FPEN, CPTR_EL2 on the EL2
  path): the stdlib's Int→String and object init use NEON; otherwise the first
  `String(123)` dies with an "Undefined Instruction" loop.
- **MMU must be on**: with it off, memory is device-like and the runtime's
  unaligned 16-byte SIMD stores fault (ESR 0x96000021). Under QEMU TCG, DMA is
  coherent with caches, so ramfb/virtio need no cache maintenance. Real
  hardware would (see the comment in MMU.swift).
- Runtime shims live in `Kernel/Support.swift` (mem*/posix_memalign/free,
  grapheme/unicode-data stubs — ASCII-correct only, `sqrt` must NOT call
  `Double.squareRoot()` — it lowers to `sqrt` and recurses — use the Newton
  version there), plus `_swift_stdlib_nfd_decompositions` (.hidden data) in
  `Kernel/Boot.S`. **Beware: the unicode stubs make `Character.isNumber` /
  `isLetter` return true for EVERY character** — never gate a scan loop on
  them; compare `unicodeScalars` values numerically instead (see
  `TerminalApp.isCSIParamChar`).
- QEMU virt addresses used: PL011 0x09000000, fw_cfg 0x09020000, GICD
  0x08000000 / GICC 0x08010000, virtio-mmio slots 0x0A000000+0x200 (legacy
  interface via `-global virtio-mmio.force-legacy=on`), RAM 0x40000000, kernel
  loaded at 0x40200000, heap region 0x40800000–0x50000000. All of these are
  now DISCOVERED from the device tree at boot (`Machine.discover`,
  Kernel/DTB.swift); the values above live on as the compiled-in defaults.
- **The DTB is NOT handed over in x0 for our ELF kernel** (QEMU
  hw/arm/boot.c): x0=dtb only applies to raw Linux-protocol `-kernel`
  images. ELF images take the bare-metal path — the CPU jumps straight to
  `_start` with x0 = 0 and QEMU ROM-loads its generated FDT at the RAM
  base 0x40000000, but ONLY if it fits below the kernel image. The FDT is
  always padded to exactly 1 MiB, and the old 0x40080000 link address left
  a 512 KiB gap, so the FDT was silently never loaded (arm_load_dtb returns
  "0 as size, i.e., no error"). link.ld therefore links the kernel at
  0x40200000; `Machine.discover` probes the RAM base when x0 is 0. Also:
  `Machine.discover` runs before the heap AND the MMU — no allocation
  (kprint family only, never klog) and NO multi-field struct returns/copies
  (their vectorized copies alignment-fault with the MMU off — the parse
  state lives in private static scalars).
- The timer IRQ handler MUST save/restore SPSR_EL1/ELR_EL1 in its stack frame
  (Vectors.S) once context switches exist — otherwise a second IRQ on another
  thread erets to the wrong PC. This was a real bug; don't regress it.
- The RAM gigabyte is mapped as an L2 table (512 x 2 MiB blocks), not a single
  L1 block: `MMU.allowEL0(base:byteCount:)` replaces the covering slot's L2
  block with an on-demand L3 table (512 x 4 KiB pages inheriting the slot's
  RAM attrs, EL1-only by default) and marks exactly the requested pages
  EL0+EL1 RW (+PXN; UXN stays clear so the user blob can execute) —
  neighbouring heap pages in the slot stay EL1-only, so an EL0 access
  outside its window faults and is contained by UserProcess. Don't fold it
  back into an L1 block — EL0 userspace (Kernel/Userspace.swift) depends on
  the L2/L3 split. The lower-EL vector
  rows in Vectors.S are live: sync_lower_entry's 176-byte frame contract with
  swift_sync_lower (x0-x18, x30, SPSR, ELR) is unchanged — but irq_entry's
  frame is now a LARGER 304-byte one (x0-x18, x30, SPSR, ELR at the same
  offsets 0-175, plus q0-q7 at 176-303, because NEON caller-saved regs were
  a preemption corruption hole). Keep the offsets 0-175 of the two frames
  identical.
- Scheduled user processes (round 6) get PER-PROCESS page tables: L1 slot 9
  (`MMU.userSlot`, VA 0x2_4000_0000) is the userspace gigabyte — every
  process's blob+stack live at the SAME VAs there, translated by the
  process's own L2/L3 (`MMU.makeUserMap`, only its two pages mapped —
  everything else faults). Each core has a private L0/L1 pair (cpu 0 keeps
  the boot tables; secondaries' clones are pre-built in `MMU.initMMU` and
  installed by `MMU.useCoreTables` from `Scheduler.runCore`), so two
  processes can be at EL0 simultaneously on two cores. The scheduler's
  switch hook installs/clears the incoming thread's L2 in the core's
  L1[9] + flushes the local TLB on EVERY switch where it differs (one
  compare; kernel<->kernel switches skip it) — migration re-installs on
  the new core automatically. AND: SP_EL0 is PER-CORE state, so the hook
  also saves the outgoing user thread's SP_EL0 into its TCB and restores
  the incoming one's — a thread resumed on a core that never dropped it
  otherwise inherits garbage/leftover SP_EL0 and its next EL0 stack access
  faults wildly (this was a real round-6 bug: level-0 translation fault in
  the blob's stack-write subroutine). The reaper frees a user thread's
  pages/L2/L3 only after runningOnCPU == -1, which (via the hook's
  every-switch discipline) guarantees no core's L1[9] or TLB can still
  translate them.
- The compositor skips present when nothing changed (SoftwareSurface.drawCalls
  + events + cursor position, 500ms staleness cap) — idle uses ~70x less CPU;
  interactive latency is one tick. Under QEMU TCG it still measures high CPU
  when animating — that's emulation, not a hang.
- `Character.isNumber`/`isLetter` return true for EVERY character (unicode
  stubs) — never gate scans on them; see `TerminalApp.isCSIParamChar`.
