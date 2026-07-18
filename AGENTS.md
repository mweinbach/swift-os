# SwiftOS

A real operating system written entirely in Swift: a bare-metal aarch64 kernel
(Embedded Swift) with a Linux-feel GUI desktop — window manager, terminal,
shell, file manager, text editor, system monitor — running on top. Boots on
QEMU's `virt` machine. No Linux, and in the kernel/userland no Apple
frameworks at all (no Foundation/CoreGraphics/AppKit/Metal).

## Layout

- `Kernel/` — the kernel: `Boot.S` (entry, EL2→EL1 drop, BSS, FP/SIMD enable,
  asm helpers), `Main.swift` (kmain + compositor loop), `UART.swift` (PL011 +
  klog/kprint + BootLog), `MMIO.swift` (volatile accessors), `Interrupts.swift`
  + `Vectors.S` (GICv2 + 100 Hz timer; the fatal sync/FIQ/SError vector stubs
  snapshot all GPRs and call `swift_fatal_exception`), `Panic.swift` (crash
  dump: full register/ESR/FAR dump + frame-pointer backtrace on serial, then
  the same text rendered onto the front framebuffer — zero allocation,
  StaticString-only, recursive-fault guard; serial-only when `Display.width`
  is 0), `Heap.swift` (page bitmap + boundary-tag
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
  + block bitmap, 4 KiB contiguous spans, write-through), `Tasks.swift` (task
  registry/CPU accounting), `Power.swift` + `PSCI.S` (PSCI 0.2 SYSTEM_OFF /
  SYSTEM_RESET over `hvc #0` — QEMU virt has no EL3 by default, so the DTB
  conduit is HVC, not SMC; QEMU exits 0 on shutdown, and on reset when
  started with `-no-reboot`), `Userspace.swift` + `Userspace.S` (EL0 userspace:
  runs an embedded unprivileged blob and services its `svc #0` ABI —
  0=write(fd 1, captured) 1=uptime_ms 2=exit 3=yield; gated by
  `Config.enableUserland`; lower-EL vector rows in `Vectors.S` route SVCs and
  EL0-preempting IRQs), `KernelServices.swift` (the `Platform.services`
  seam), `Support.swift` (libc/runtime shims), `Config.swift`.
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
  loaded at 0x40080000, heap region 0x40800000–0x50000000.
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
- The compositor skips present when nothing changed (SoftwareSurface.drawCalls
  + events + cursor position, 500ms staleness cap) — idle uses ~70x less CPU;
  interactive latency is one tick. Under QEMU TCG it still measures high CPU
  when animating — that's emulation, not a hang.
- `Character.isNumber`/`isLetter` return true for EVERY character (unicode
  stubs) — never gate scans on them; see `TerminalApp.isCSIParamChar`.
