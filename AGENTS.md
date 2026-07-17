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
  + `Vectors.S` (GICv2 + 100 Hz timer), `Heap.swift` (page bitmap + boundary-tag
  malloc backing `posix_memalign`/`free`), `MMU.swift` + `MMU.S` (identity map,
  caches), `RamFB.swift` (`Display`: fw_cfg/ramfb 1280x800 + back buffer +
  present), `VirtioInput.swift` (`Input`: virtio-mmio legacy keyboard/tablet +
  UART serial keys → `OSEvent`), `Tasks.swift` (task registry/CPU accounting),
  `KernelServices.swift` (the `Platform.services` seam), `Support.swift`
  (libc/runtime shims), `Config.swift`.
- `Userland/` — software compiled into the same module: `Geometry.swift`
  (Point/Size/Rect/Color, `CGFloat=Double`, CGRect aliases), `Events.swift`,
  `Surface.swift` (draw API **base class**), `Rasterizer.swift`
  (`SoftwareSurface`: software renderer + alpha + clip + text),
  `FontData.swift` (generated 8x16 Menlo bitmap), `TimeFmt.swift` (TimeFmt +
  NumFmt — no Foundation formatting), `Services.swift` (ProcessInfo +
  `Platform.services`), `WindowManager.swift` (`OSApp` **base class**, OSWindow,
  WindowManager), `Desktop.swift`, `Terminal.swift`, `Shell.swift`, `VFS.swift`
  (in-memory Linux-like tree, typed throws), `FileManagerApp.swift`,
  `TextEditorApp.swift`, `SystemMonitorApp.swift`.
- `tools/genfont.swift` — macOS/CoreText generator that produces FontData.swift.
- `Host-macOS/` — the earlier macOS SwiftPM harness (Metal/AppKit app showing
  the same desktop). Secondary; the kernel is the product.
- `Makefile`, `link.ld` — kernel build.

## Build & run

```sh
make            # builds build/swiftos.elf (swiftly Swift 6.2, Embedded Swift)
make run        # QEMU virt + ramfb + virtio keyboard/tablet + cocoa window
make serial     # headless, serial on stdio
make font       # regenerate Userland/FontData.swift (needs macOS CoreText)
make app        # build the Host-macOS harness
```

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
  `Kernel/Boot.S`.
- QEMU virt addresses used: PL011 0x09000000, fw_cfg 0x09020000, GICD
  0x08000000 / GICC 0x08010000, virtio-mmio slots 0x0A000000+0x200 (legacy
  interface via `-global virtio-mmio.force-legacy=on`), RAM 0x40000000, kernel
  loaded at 0x40080000, heap region 0x40800000–0x50000000.
- `make run` is slow-ish under TCG (~25 fps wall) — that's emulation speed,
  not a hang. The compositor genuinely measures ~100% CPU in System Monitor.
