// ============================================================================
// Panic — the kernel's last words: a full crash dump on serial plus a
// direct-to-framebuffer panic screen, then halt.
//
// Entry points:
//   - Panic.fatal(kind:esr:elr:far:spsr:regs:) — reached from the Vectors.S
//     fatal stubs via swift_fatal_exception (Kernel/Interrupts.swift) for
//     every fatal exception: synchronous at EL1, FIQ, SError, unexpected
//     vector. `regs` is the Vectors.S snapshot: [0...30] = x0...x30 at the
//     exception, [31] = the exception-time SP. kind: 0 = sync, 1 = FIQ,
//     2 = SError, 3 = unexpected vector.
//   - Panic.halt(_:) — String-message panics (the kpanic upgrade path).
//
// Hard rules in this file — a panic can strike with the heap corrupt, the
// scheduler mid-switch, or the compositor half-drawn:
//   - ZERO allocation, ZERO Swift containers, no String building, no
//     retain/release. Output is PL011 MMIO writes + plain pointer stores
//     only; text is StaticString literals and a table-free hex formatter.
//   - SERIAL FIRST, SCREEN SECOND: the whole dump is emitted once with the
//     screen gated off (serial cannot fail — it is pure MMIO), then emitted
//     again onto the front framebuffer. If the screen pass itself dies
//     (e.g. binding the lazily-initialized font array touches a dead heap),
//     the serial dump is already complete and the recursive guard reports
//     the second fault.
//   - RECURSIVE FAULT GUARD: `entered` is set on first entry; any re-entry
//     prints "RECURSIVE FAULT" + minimal info to serial and halts
//     immediately — no second dump, no screen work.
//   - The on-screen renderer writes the FRONT buffer (Display.framebuffer)
//     pixel-by-pixel with plain pointer stores. The compositor is dead by
//     definition, so the front buffer is the only thing the user can see.
//     If the display was never initialized (Display.width == 0 — headless
//     or early boot), the panic is serial-only.
// ============================================================================

@_silgen_name("arm_mask_all") private func armMaskAll()

enum Panic {
    /// Bounds for validating frame-pointer chain links before dereferencing:
    /// kernel image base (0x4008_0000) .. end of the heap region
    /// (0x8080_0000). Boot stack (BSS) and all thread stacks (heap pages)
    /// live inside this window; anything outside is not a sane frame link.
    private static let chainLo: UInt64 = 0x4008_0000
    private static let chainHi: UInt64 = 0x8080_0000

    /// Frame-pointer chain walk cap.
    private static let maxFrames: UInt64 = 16

    // XR24 pixel values (0xFFRRGGBB), matching RamFB.
    private static let colorBlack: UInt32 = 0xFF00_0000
    private static let colorRed:   UInt32 = 0xFFFF_0000
    private static let colorWhite: UInt32 = 0xFFFF_FFFF

    private static let marginX = 16
    private static let topY = 16
    private static let lineH = 18          // 16px glyph + 2px gap

    /// Non-zero once any panic path has been entered (recursive-fault guard).
    private static var entered: UInt8 = 0

    /// Font glyph base, bound on the first screen pass. FontData.bitmap is a
    /// static let whose storage lives for the life of the kernel, so holding
    /// its base pointer past withUnsafeBufferPointer's scope is sound here.
    /// Bound lazily: an early-boot panic may be the array's first touch.
    private static var glyphs: UnsafePointer<UInt8>?

    /// Screen pen state (plain Ints — no containers).
    private static var penX = 0
    private static var penY = 0
    private static var penColor: UInt32 = 0xFFFF_FFFF
    /// Output gates: pass 1 = serial only, pass 2 = screen only.
    private static var serialOn = true
    private static var screenOn = false

    // MARK: - Entry points

    /// Fatal exception dump + halt. Never returns.
    static func fatal(kind: UInt64, esr: UInt64, elr: UInt64, far: UInt64,
                      spsr: UInt64, regs: UnsafePointer<UInt64>) -> Never {
        armMaskAll()
        if entered != 0 {
            serialOn = true
            screenOn = false
            out("\nRECURSIVE FAULT kind=")
            outDec(kind)
            out(" ELR=")
            outHex(elr)
            out("\n")
            hardHalt()
        }
        entered = 1

        // Pass 1: serial only — cannot fail (PL011 MMIO).
        serialOn = true
        screenOn = false
        emitDump(kind: kind, esr: esr, elr: elr, far: far, spsr: spsr, regs: regs)

        // Pass 2: best-effort render onto the front buffer.
        if Display.width > 0 {
            bindGlyphs()
            screenClear()
            serialOn = false
            screenOn = true
            emitDump(kind: kind, esr: esr, elr: elr, far: far, spsr: spsr, regs: regs)
            screenOn = false
        }
        hardHalt()
    }

    /// String-message panic (kpanic upgrade path): same serial-then-screen
    /// discipline, but no register snapshot exists at this level.
    /// `reason` must be a literal or otherwise pre-built string — building a
    /// string INSIDE the panic path would allocate.
    static func halt(_ reason: String) -> Never {
        armMaskAll()
        if entered != 0 {
            serialOn = true
            screenOn = false
            out("\nRECURSIVE FAULT (panic message path)\n")
            hardHalt()
        }
        entered = 1

        serialOn = true
        screenOn = false
        emitMessage(reason)

        if Display.width > 0 {
            bindGlyphs()
            screenClear()
            serialOn = false
            screenOn = true
            emitMessage(reason)
            screenOn = false
        }
        hardHalt()
    }

    // MARK: - Dump composition

    private static func emitDump(kind: UInt64, esr: UInt64, elr: UInt64,
                                 far: UInt64, spsr: UInt64,
                                 regs: UnsafePointer<UInt64>) {
        let ec = (esr >> 26) & 0x3F
        penColor = colorRed
        out("\n*** KERNEL PANIC ***\n")
        out("reason: ")
        if let name = kindName(kind) {
            out(name)
        } else {
            out("exception kind=")
            outDec(kind)
        }
        out(": ")
        if let name = ecName(ec) {
            out(name)
        } else {
            out("unrecognized EC=")
            outHexByte(ec)
        }
        out("\n")

        penColor = colorWhite
        out("ESR=")
        outHex(esr)
        out(" ELR=")
        outHex(elr)
        out(" FAR=")
        outHex(far)
        out(" SPSR=")
        outHex(spsr)
        out("\n")

        // ISS decode for the abort ECs (and SError's DFSC).
        if ec == 0x24 || ec == 0x25 {
            out("abort: data, ")
            out(esr & 0x40 != 0 ? "write" : "read")   // ISS.WnR (bit 6)
            out(" access - ")
            outDfsc(esr & 0x3F)
            out("\n")
        } else if ec == 0x20 || ec == 0x21 {
            out("abort: instruction fetch - ")
            outDfsc(esr & 0x3F)
            out("\n")
        } else if ec == 0x2F {
            out("serror ISS: ")
            outDfsc(esr & 0x3F)
            out("\n")
        }

        // Registers: four per line, x0...x30 then the exception-time SP.
        var i = 0
        while i < 32 {
            var j = 0
            while j < 4 {
                let n = i + j
                if n > 31 { break }
                outRegName(n)
                out("= ")
                outHex(regs[n])
                out("  ")
                j += 1
            }
            out("\n")
            i += 4
        }

        // Frame-pointer backtrace: [x29] = next link, [x29+8] = return addr.
        // Links are validated against the kernel/heap window BEFORE any
        // dereference, must stay 8-byte aligned, and must climb the stack.
        out("backtrace:\n")
        var fp = regs[29]
        var frames: UInt64 = 0
        while frames < maxFrames {
            if !chainValid(fp) { break }
            let lr = load64(fp &+ 8)
            if lr == 0 { break }
            out("  #")
            outDec(frames)
            out("  fp=")
            outHex(fp)
            out("  lr=")
            outHex(lr)
            out("\n")
            let next = load64(fp)
            if next <= fp { break }
            fp = next
            frames += 1
        }
        if frames == 0 { out("  (no valid frames)\n") }

        penColor = colorRed
        out("\nsystem halted\n")
    }

    private static func emitMessage(_ reason: String) {
        penColor = colorRed
        out("\n*** KERNEL PANIC ***\nreason: ")
        for b in reason.utf8 {          // byte view of an existing String: no allocation
            out(b)
        }
        out("\n\nsystem halted\n")
    }

    // MARK: - Decode tables (StaticString literals: no allocation)

    private static func kindName(_ kind: UInt64) -> StaticString? {
        switch kind {
        case 0: return "synchronous exception at EL1"
        case 1: return "FIQ at EL1"
        case 2: return "SError at EL1"
        case 3: return "unexpected exception vector"
        default: return nil
        }
    }

    /// ESR_EL1.EC (bits 31:26) to text.
    private static func ecName(_ ec: UInt64) -> StaticString? {
        switch ec {
        case 0x00: return "unknown reason"
        case 0x01: return "WFI/WFE trap"
        case 0x07: return "FP/SIMD access trap"
        case 0x0E: return "illegal execution state"
        case 0x15: return "SVC from AArch64"
        case 0x18: return "MSR/MRS/system instruction trap (AArch64)"
        case 0x20: return "instruction abort from a lower EL"
        case 0x21: return "instruction abort at EL1"
        case 0x22: return "PC alignment fault"
        case 0x24: return "data abort from a lower EL"
        case 0x25: return "data abort at EL1"
        case 0x26: return "SP alignment fault"
        case 0x2F: return "SError"
        default: return nil
        }
    }

    /// ISS.DFSC (bits 5:0) to text — data/instruction aborts and SError.
    private static func outDfsc(_ dfsc: UInt64) {
        switch dfsc {
        case 0x00...0x03:
            out("address size fault, level ")
            outLevel(dfsc)
        case 0x04...0x07:
            out("translation fault, level ")
            outLevel(dfsc)
        case 0x08...0x0B:
            out("access flag fault, level ")
            outLevel(dfsc)
        case 0x0C...0x0F:
            out("permission fault, level ")
            outLevel(dfsc)
        case 0x10:
            out("synchronous external abort")
        case 0x11:
            out("asynchronous external abort")
        case 0x14...0x17:
            out("synchronous external abort on table walk, level ")
            outLevel(dfsc)
        case 0x21:
            out("alignment fault")
        case 0x30:
            out("TLB conflict abort")
        default:
            out("DFSC=")
            outHexByte(dfsc)
        }
    }

    private static func outLevel(_ dfsc: UInt64) {
        out(UInt8(48) + UInt8(dfsc & 3))
    }

    // MARK: - Emitters (UART MMIO + optional screen; nothing allocates)

    private static func out(_ b: UInt8) {
        if serialOn { UART.putc(b) }
        if screenOn { screenPutc(b) }
    }

    private static func out(_ s: StaticString) {
        let base = s.utf8Start
        var i = 0
        while i < s.utf8CodeUnitCount {
            out(base[i])
            i += 1
        }
    }

    /// "0x" + 16 hex digits, table-free.
    private static func outHex(_ v: UInt64) {
        out("0x")
        var shift = 60
        while shift >= 0 {
            out(hexDigit(UInt8((v >> shift) & 0xF)))
            shift -= 4
        }
    }

    /// "0x" + 2 hex digits.
    private static func outHexByte(_ v: UInt64) {
        out("0x")
        out(hexDigit(UInt8((v >> 4) & 0xF)))
        out(hexDigit(UInt8(v & 0xF)))
    }

    private static func hexDigit(_ n: UInt8) -> UInt8 {
        n < 10 ? 48 + n : 87 + n        // '0'..'9', 'a'..'f'
    }

    /// Decimal, 0...99 (register indices, frame numbers, kind codes).
    private static func outDec(_ v: UInt64) {
        if v >= 10 { out(UInt8(48) + UInt8((v / 10) % 10)) }
        out(UInt8(48) + UInt8(v % 10))
    }

    /// Register field name, padded to 3 chars: "x0 ", "x15", "sp ".
    private static func outRegName(_ n: Int) {
        if n == 31 {
            out("sp ")
            return
        }
        out("x")
        outDec(UInt64(n))
        if n < 10 { out(" ") }
    }

    // MARK: - Backtrace memory access (addresses pre-validated by chainValid)

    private static func chainValid(_ fp: UInt64) -> Bool {
        fp >= chainLo && fp <= chainHi &- 16 && fp & 7 == 0
    }

    private static func load64(_ addr: UInt64) -> UInt64 {
        UnsafePointer<UInt64>(bitPattern: UInt(addr))!.pointee
    }

    // MARK: - Screen renderer (front buffer, plain pointer stores only)

    private static func bindGlyphs() {
        if glyphs != nil { return }
        FontData.bitmap.withUnsafeBufferPointer { glyphs = $0.baseAddress }
    }

    private static func screenClear() {
        penX = marginX
        penY = topY
        penColor = colorWhite
        let fb = Display.framebuffer
        let total = Display.strideBytes * Display.height
        let pair = UInt64(colorBlack) << 32 | UInt64(colorBlack)
        var off = 0
        while off + 8 <= total {
            fb.storeBytes(of: pair, toByteOffset: off, as: UInt64.self)
            off += 8
        }
        while off < total {
            fb.storeBytes(of: colorBlack, toByteOffset: off, as: UInt32.self)
            off += 4
        }
    }

    private static func screenPutc(_ b: UInt8) {
        if b == 10 {
            penX = marginX
            penY += lineH
            return
        }
        if penX + FontData.cellWidth > Display.width {
            penX = marginX
            penY += lineH
        }
        // Off the bottom: stop drawing — the serial dump already has it.
        if penY + FontData.cellHeight > Display.height { return }
        drawGlyph(b)
        penX += FontData.cellWidth
    }

    private static func drawGlyph(_ b: UInt8) {
        guard let glyphs else { return }
        var s = b
        if s < UInt8(FontData.firstScalar) || s > UInt8(FontData.lastScalar) {
            s = 63                      // '?'
        }
        let glyphBase = Int(s - UInt8(FontData.firstScalar)) &* FontData.bytesPerGlyph
        let fb = Display.framebuffer
        let stride = Display.strideBytes
        var row = 0
        while row < FontData.cellHeight {
            let bits = glyphs[glyphBase + row]
            var mask: UInt8 = 0x80
            var col = 0
            while col < FontData.cellWidth {
                if bits & mask != 0 {
                    fb.storeBytes(of: penColor,
                                  toByteOffset: (penY + row) &* stride &+ (penX + col) &* 4,
                                  as: UInt32.self)
                }
                mask >>= 1
                col += 1
            }
            row += 1
        }
    }

    // MARK: - Halt

    private static func hardHalt() -> Never {
        armMaskAll()
        while true { armWfi() }
    }
}
