// Machine discovery from the flattened device tree (FDT) QEMU hands over.
//
// How the DTB reaches the kernel (QEMU hw/arm/boot.c, verified on QEMU 11):
//   - Raw Linux-protocol -kernel image: QEMU's bootloader stub passes the
//     DTB address in x0.
//   - ELF -kernel image (our build): bare-metal boot — the CPU jumps
//     straight to _start with x0 = 0 (verified: x0 is 0 at the very first
//     instruction), and QEMU ROM-loads its generated FDT at the RAM base
//     0x4000_0000 — but ONLY if it fits below the kernel image. The
//     generated FDT is always padded to exactly 1 MiB (FDT_MAX_SIZE), and
//     the old 0x4008_0000 link address left a 512 KiB gap, so the FDT was
//     silently never loaded (arm_load_dtb "returns 0 as size, i.e., no
//     error"). link.ld now links the kernel at 0x4020_0000, and discover()
//     probes the RAM base whenever x0 arrives as 0.
//
// Every field keeps the previously hardcoded value as its default: a
// missing/unparseable DTB — or a single missing node — leaves the
// compiled-in defaults in place, so any regression degrades to the old
// behavior instead of breaking the boot.
//
// discover() runs BEFORE KernelHeap.initHeap AND before MMU.initMMU. Two
// hard consequences:
//   - Never allocate: no String interpolation, no arrays, no klog (BootLog
//     allocates) — logging uses the allocation-free kprint* family only.
//   - With the MMU off, memory is device-like and UNALIGNED 16-byte SIMD
//     accesses fault (ESR 0x96000021/61 — observed: the compiler's
//     vectorized copy of a returned struct alignment-faulted at an 8 mod 16
//     stack slot). This file therefore keeps ALL parse state in private
//     static scalars and never returns/copies multi-field structs or
//     tuples: scalar returns and scalar static stores only.
//
// All FDT reads are plain byte loads from RAM and the walk is fully
// bounds-checked, so a corrupt or bogus blob yields `false`, never a fault.

/// Discovered machine description. Consumers read these fields instead of
/// hardcoding QEMU virt addresses; discover() fills them from the FDT and
/// every field keeps its compiled-in default on any failure.
enum Machine {
    /// Total RAM in MiB (from the /memory reg property). Default: Config.
    static private(set) var ramSizeMB: Int = Config.ramMB
    /// PL011 UART base (/pl011 node reg).
    static private(set) var uartBase: UInt = 0x0900_0000
    /// GIC distributor base (/intc node reg, first tuple).
    static private(set) var gicdBase: UInt = 0x0800_0000
    /// GIC CPU interface base (/intc node reg, second tuple).
    static private(set) var giccBase: UInt = 0x0801_0000
    /// fw_cfg device base (/fw-cfg node reg).
    static private(set) var fwCfgBase: UInt = 0x0902_0000
    /// First virtio-mmio slot base (first /virtio_mmio node reg).
    static private(set) var virtioMmioBase: UInt = 0x0A00_0000
    /// Number of virtio-mmio slots to scan (/virtio_mmio node count,
    /// capped at the virt machine's 32).
    static private(set) var virtioMmioSlots: Int = 32
    /// Number of CPUs (/cpus/cpu@N node count). Default: Config.
    static private(set) var cpuCount: Int = Config.cpuCount
    /// True after discover() parsed a structurally valid FDT (even when
    /// some nodes were absent and their defaults survived).
    static private(set) var discovered = false

    /// RAM base on QEMU virt — the documented FDT location for bare-metal
    /// (ELF) boots, probed when x0 carries no pointer.
    private static let ramBase: UInt = 0x4000_0000

    // MARK: - Parse workspace (private static scalars — see the header:
    // struct returns/copies can alignment-fault while the MMU is off)

    // Validated blob layout: byte offsets into the blob at fdtBase.
    private static var fdtBase: UInt = 0
    private static var fdtStructStart = 0
    private static var fdtStructEnd = 0
    private static var fdtStringsStart = 0
    private static var fdtStringsEnd = 0

    // Walk state; committed to the public fields only after a clean pass.
    private static var psAddrCells = 2
    private static var psSizeCells = 2
    private static var psRamBytes: UInt64 = 0
    private static var psSawMemory = false
    private static var psUart: UInt = 0
    private static var psSawUART = false
    private static var psGicd: UInt = 0
    private static var psGicc: UInt = 0
    private static var psSawGIC = false
    private static var psFwCfg: UInt = 0
    private static var psSawFwCfg = false
    private static var psVirtioBase: UInt = 0
    private static var psSawVirtioBase = false
    private static var psVirtioCount = 0
    private static var psCpus = 0
    private static var psPsciMethodOff = -1
    private static var psPsciMethodLen = 0

    // Outputs of readReg (valid when it returns true).
    private static var regAddrOut: UInt64 = 0
    private static var regSizeOut: UInt64 = 0

    /// Depth-1 node classification (all nodes of interest are direct
    /// children of root; /cpus is special only because its cpu@ children
    /// are counted at depth 2).
    private enum Kind {
        case none, memory, pl011, intc, fwCfg, virtio, psci, cpus, other
    }

    // FDT token values.
    private static let tokBeginNode: UInt32 = 1
    private static let tokEndNode: UInt32 = 2
    private static let tokProp: UInt32 = 3
    private static let tokNop: UInt32 = 4
    private static let tokEnd: UInt32 = 9

    // MARK: - Entry point

    /// Discover the machine from the FDT at `dtb` (x0 at kernel entry).
    /// When `dtb` is 0 — QEMU's ELF bare-metal boot path — the RAM base is
    /// probed instead. On success the parsed values replace the compiled-in
    /// defaults and the UART is re-pointed if the tree names a different
    /// PL011. Returns false (defaults untouched) for any bogus input.
    static func discover(dtb: UInt) -> Bool {
        var probe = dtb
        if probe == 0 {
            kprint("[dtb] no DTB pointer in x0 (bare-metal ELF boot) — probing RAM base ")
            kprintHex(UInt64(ramBase))
            kprint("\n")
            probe = ramBase
        }
        guard validate(probe) else {
            kprint("[dtb] no usable FDT at ")
            kprintHex(UInt64(probe))
            kprint(" — compiled-in machine defaults in use\n")
            return false
        }

        resetState()
        // Root #address-cells/#size-cells drive reg decoding for the board
        // nodes (all direct children of root). Spec default is 2.
        guard readRootCells() else {
            kprint("[dtb] FDT structure corrupt (cells pass) — defaults in use\n")
            return false
        }
        guard walk() else {
            kprint("[dtb] FDT structure corrupt — defaults in use\n")
            return false
        }
        commit()
        discovered = true
        return true
    }

    private static func resetState() {
        psAddrCells = 2
        psSizeCells = 2
        psRamBytes = 0
        psSawMemory = false
        psSawUART = false
        psSawGIC = false
        psSawFwCfg = false
        psSawVirtioBase = false
        psVirtioCount = 0
        psCpus = 0
        psPsciMethodOff = -1
        psPsciMethodLen = 0
    }

    // MARK: - FDT layout validation

    /// Header check: alignment, magic, and a totalsize/offset envelope that
    /// keeps every later read inside the blob. Never dereferences a
    /// misaligned pointer. On success the fdt* workspace is set.
    private static func validate(_ addr: UInt) -> Bool {
        guard addr & 7 == 0 else { return false }        // FDT is 8-aligned
        guard be32(addr, 0) == 0xD00D_FEED else { return false }
        let total = Int(be32(addr, 4))
        guard total >= 64, total <= 8 * 1024 * 1024 else { return false }
        let offStruct = Int(be32(addr, 8))
        let offStrings = Int(be32(addr, 12))
        let sizeStrings = Int(be32(addr, 32))
        let sizeStruct = Int(be32(addr, 36))
        guard offStruct & 3 == 0, offStruct >= 40,
              sizeStruct >= 4, offStruct + sizeStruct <= total,
              offStrings + sizeStrings <= total else { return false }
        fdtBase = addr
        fdtStructStart = offStruct
        fdtStructEnd = offStruct + sizeStruct
        fdtStringsStart = offStrings
        fdtStringsEnd = offStrings + sizeStrings
        return true
    }

    // MARK: - Primitive readers (big-endian, byte-assembled, no alignment
    // requirements — the MMU is still off at this point in boot)

    private static func byte(_ base: UInt, _ off: Int) -> UInt8 {
        UnsafeRawPointer(bitPattern: base + UInt(off))!.load(as: UInt8.self)
    }

    private static func be32(_ base: UInt, _ off: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(byte(base, off + i)) }
        return v
    }

    /// Length of the NUL-terminated name at `off`, or -1 when no NUL shows
    /// up before `limit` (or a 64-byte sanity cap). The struct and strings
    /// blocks pass their own ends as the limit, so a corrupt blob can never
    /// send the scan out of bounds.
    private static func nameLength(_ off: Int, _ limit: Int) -> Int {
        let cap = min(limit, off + 64)
        var i = off
        while i < cap {
            if byte(fdtBase, i) == 0 { return i - off }
            i += 1
        }
        return -1
    }

    private static func hasPrefix(_ off: Int, _ len: Int, _ prefix: StaticString) -> Bool {
        guard len >= prefix.utf8CodeUnitCount else { return false }
        for i in 0..<prefix.utf8CodeUnitCount where byte(fdtBase, off + i) != prefix.utf8Start[i] {
            return false
        }
        return true
    }

    private static func isName(_ off: Int, _ len: Int, _ name: StaticString) -> Bool {
        len == name.utf8CodeUnitCount && hasPrefix(off, len, name)
    }

    private static func classify(_ off: Int, _ len: Int) -> Kind {
        if hasPrefix(off, len, "memory") { return .memory }
        if hasPrefix(off, len, "pl011@") { return .pl011 }
        if hasPrefix(off, len, "intc@") { return .intc }
        if hasPrefix(off, len, "fw-cfg@") { return .fwCfg }
        if hasPrefix(off, len, "virtio_mmio@") { return .virtio }
        if isName(off, len, "psci") { return .psci }
        if isName(off, len, "cpus") { return .cpus }
        return .other
    }

    /// Decode reg tuple `tuple` (`psAddrCells` address cells then
    /// `psSizeCells` size cells) into regAddrOut/regSizeOut. Returns false
    /// for unsupported cell counts or a truncated property — the caller
    /// then simply keeps the corresponding default.
    private static func readReg(_ dataOff: Int, _ dataLen: Int, _ tuple: Int) -> Bool {
        let ac = psAddrCells
        let sc = psSizeCells
        guard ac >= 1, ac <= 2, sc >= 1, sc <= 2 else { return false }
        let tupleBytes = (ac + sc) * 4
        let start = tuple * tupleBytes
        guard start >= 0, start + tupleBytes <= dataLen else { return false }
        var addr: UInt64 = 0
        for i in 0..<ac { addr = (addr << 32) | UInt64(be32(fdtBase, dataOff + start + i * 4)) }
        var size: UInt64 = 0
        for i in 0..<sc { size = (size << 32) | UInt64(be32(fdtBase, dataOff + start + ac * 4 + i * 4)) }
        regAddrOut = addr
        regSizeOut = size
        return true
    }

    // MARK: - Struct-block walks

    /// First pass: only the root node's #address-cells/#size-cells, so the
    /// reg properties in the second pass decode correctly regardless of
    /// where a generator places them relative to child nodes.
    private static func readRootCells() -> Bool {
        var pos = fdtStructStart
        var depth = 0
        while pos + 4 <= fdtStructEnd {
            let token = be32(fdtBase, pos)
            pos += 4
            switch token {
            case tokBeginNode:
                let len = nameLength(pos, fdtStructEnd)
                guard len >= 0 else { return false }
                depth += 1
                pos += (len + 1 + 3) & ~3
            case tokEndNode:
                depth -= 1
                guard depth >= 0 else { return false }
            case tokProp:
                guard pos + 8 <= fdtStructEnd else { return false }
                let len = Int(be32(fdtBase, pos))
                let nameOff = Int(be32(fdtBase, pos + 4))
                guard len >= 0, pos + 8 + len <= fdtStructEnd,
                      nameOff >= 0, fdtStringsStart + nameOff < fdtStringsEnd else { return false }
                let pOff = fdtStringsStart + nameOff
                let pLen = nameLength(pOff, fdtStringsEnd)
                guard pLen >= 0 else { return false }
                if depth == 1, len == 4 {      // property of the root node
                    if isName(pOff, pLen, "#address-cells") {
                        psAddrCells = Int(be32(fdtBase, pos + 8))
                    } else if isName(pOff, pLen, "#size-cells") {
                        psSizeCells = Int(be32(fdtBase, pos + 8))
                    }
                }
                pos += 8 + ((len + 3) & ~3)
            case tokNop:
                break
            case tokEnd:
                return depth == 0
            default:
                return false
            }
        }
        return false                                     // never saw FDT_END
    }

    /// Second pass: the board nodes. Anything unreadable per-property skips
    /// just that property; only a corrupt token STREAM fails the walk.
    private static func walk() -> Bool {
        var pos = fdtStructStart
        var depth = 0
        var kind1 = Kind.none
        while pos + 4 <= fdtStructEnd {
            let token = be32(fdtBase, pos)
            pos += 4
            switch token {
            case tokBeginNode:
                let len = nameLength(pos, fdtStructEnd)
                guard len >= 0 else { return false }
                if depth == 1 {
                    kind1 = classify(pos, len)
                    if kind1 == .virtio { psVirtioCount += 1 }
                } else if depth == 2, kind1 == .cpus, hasPrefix(pos, len, "cpu@") {
                    psCpus += 1
                }
                depth += 1
                pos += (len + 1 + 3) & ~3
            case tokEndNode:
                depth -= 1
                guard depth >= 0 else { return false }
                if depth <= 1 { kind1 = .none }
            case tokProp:
                guard pos + 8 <= fdtStructEnd else { return false }
                let len = Int(be32(fdtBase, pos))
                let nameOff = Int(be32(fdtBase, pos + 4))
                guard len >= 0, pos + 8 + len <= fdtStructEnd,
                      nameOff >= 0, fdtStringsStart + nameOff < fdtStringsEnd else { return false }
                let pOff = fdtStringsStart + nameOff
                let pLen = nameLength(pOff, fdtStringsEnd)
                guard pLen >= 0 else { return false }
                if depth == 2 {                      // property of a board node
                    applyProp(kind1, nameOff: pOff, nameLen: pLen,
                              dataOff: pos + 8, dataLen: len)
                }
                pos += 8 + ((len + 3) & ~3)
            case tokNop:
                break
            case tokEnd:
                return depth == 0
            default:
                return false
            }
        }
        return false
    }

    /// Handle one depth-2 (board-node) property. `nameOff` is absolute
    /// (into the strings block), `dataOff`/`dataLen` locate the value.
    private static func applyProp(_ kind: Kind, nameOff: Int, nameLen: Int,
                                  dataOff: Int, dataLen: Int) {
        switch kind {
        case .memory:
            guard isName(nameOff, nameLen, "reg") else { return }
            var tuple = 0
            while readReg(dataOff, dataLen, tuple) {
                psRamBytes += regSizeOut
                psSawMemory = true
                tuple += 1
            }
        case .pl011:
            guard isName(nameOff, nameLen, "reg") else { return }
            if readReg(dataOff, dataLen, 0) {
                psUart = UInt(regAddrOut)
                psSawUART = true
            }
        case .intc:
            guard isName(nameOff, nameLen, "reg") else { return }
            if readReg(dataOff, dataLen, 0) {
                psGicd = UInt(regAddrOut)
                psSawGIC = true
            }
            if readReg(dataOff, dataLen, 1) {
                psGicc = UInt(regAddrOut)
            }
        case .fwCfg:
            guard isName(nameOff, nameLen, "reg") else { return }
            if readReg(dataOff, dataLen, 0) {
                psFwCfg = UInt(regAddrOut)
                psSawFwCfg = true
            }
        case .virtio:
            guard isName(nameOff, nameLen, "reg") else { return }
            if !psSawVirtioBase, readReg(dataOff, dataLen, 0) {
                psVirtioBase = UInt(regAddrOut)
                psSawVirtioBase = true
            }
        case .psci:
            guard isName(nameOff, nameLen, "method") else { return }
            if dataLen >= 1, dataLen <= 8 {
                psPsciMethodOff = dataOff
                psPsciMethodLen = dataLen
            }
        default:
            return
        }
    }

    // MARK: - Commit + logging

    /// Publish the parsed state over the defaults (only for nodes actually
    /// found), re-point the UART if the tree moved it, and log the summary.
    private static func commit() {
        if psSawMemory, psRamBytes > 0 {
            ramSizeMB = Int(psRamBytes >> 20)
        }
        if psSawUART {
            uartBase = psUart
        }
        if psSawGIC {
            gicdBase = psGicd
            if psGicc != 0 { giccBase = psGicc }
        }
        if psSawFwCfg {
            fwCfgBase = psFwCfg
        }
        if psVirtioCount > 0 {
            if psSawVirtioBase { virtioMmioBase = psVirtioBase }
            virtioMmioSlots = min(psVirtioCount, 32)
        }
        if psCpus > 0 {
            cpuCount = psCpus
        }

        // The DTB's PL011 replaces the fallback base (and gets initialized
        // there); unchanged on QEMU virt.
        UART.setBase(uartBase)

        let lock = armKlogLockAddr()
        armSpinLock(lock)
        kprintUnlocked("[dtb] ram ")
        kprintDecUnlocked(Int64(ramSizeMB))
        kprintUnlocked(" MB, ")
        kprintDecUnlocked(Int64(cpuCount))
        kprintUnlocked(" cpus, gic ")
        hexShortUnlocked(gicdBase)
        kprintUnlocked("/")
        hexShortUnlocked(giccBase)
        kprintUnlocked(", uart ")
        hexShortUnlocked(uartBase)
        kprintUnlocked("\n")

        kprintUnlocked("[dtb] fw-cfg ")
        hexShortUnlocked(fwCfgBase)
        kprintUnlocked(", virtio-mmio ")
        hexShortUnlocked(virtioMmioBase)
        kprintUnlocked(", ")
        kprintDecUnlocked(Int64(virtioMmioSlots))
        kprintUnlocked(" slots\n")

        kprintUnlocked("[dtb] psci method: ")
        if psPsciMethodOff >= 0 {
            for i in 0..<psPsciMethodLen {
                let c = byte(fdtBase, psPsciMethodOff + i)
                if c == 0 { break }
                UART.putc(c)
            }
        } else {
            kprintUnlocked("unknown (hvc assumed)")
        }
        kprintUnlocked("\n")
        armSpinUnlock(lock)
    }

    /// `0x` + lowercase hex without leading zeros. Caller holds the klog
    /// lock; allocation-free like the rest of this file.
    private static func hexShortUnlocked(_ v: UInt) {
        kprintUnlocked("0x")
        var started = false
        var shift = 60
        while shift >= 0 {
            let d = UInt8((v >> UInt(shift)) & 0xF)
            if d != 0 || started || shift == 0 {
                started = true
                UART.putc(d < 10 ? 48 + d : 87 + d)
            }
            shift -= 4
        }
    }
}
