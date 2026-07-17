// ============================================================================
// MMU — stage-1 address translation for EL1 (AArch64, 4 KiB granule).
//
// Identity map: virtual address == physical address everywhere, TTBR0_EL1
// only, no ASIDs (all entries global). Two pages of tables, bump-allocated
// from KernelHeap (never freed — they must live forever):
//
//   L0 (1 page, zeroed):
//     L0[0]  -> L1 table
//   L1 (1 page, zeroed):
//     L1[0]  = 1 GiB block [0x0000_0000, 0x4000_0000)
//              device-nGnRnE (MAIR attr0), PXN — UART, GIC, virtio-mmio
//     L1[1]  -> L2 table (the RAM gigabyte, split so single 2 MiB slots can
//              carry different AP/XP bits — the EL0 userspace window needs
//              EL0-accessible pages; see allowEL0 below)
//     rest   = invalid
//   L2 (1 page, 512 entries):
//     L2[i]  = 2 MiB block [0x4000_0000 + i*2MiB, +2MiB)
//              normal inner+outer write-back cacheable, inner shareable
//              (MAIR attr1) — covers all 512 MiB of RAM plus kernel/heap.
//              Identical attrs to the former 1 GiB L1 block: same
//              translation, one extra walk level.
//
// TCR.T0SZ = 24 (40-bit VA) — deliberately NOT 25: with a 4 KiB granule a
// 39-bit VA (T0SZ=25) makes the hardware table walk START at level 1, so
// TTBR0 would have to point at the L1 table and the L0->L1 topology above
// would be misinterpreted (L0[0] read as a level-1 entry, L1 entries read
// as 2 MiB level-2 blocks — UART at 0x0900_0000 unmapped, instant data
// abort). T0SZ=24 starts the walk at level 0, which is what the L0[0]->L1
// design requires; a 40-bit VA also matches TCR.IPS (40-bit PA, 1 TB).
//
// Call initMMU() exactly once, after KernelHeap.initHeap() (it needs
// allocPages + klog), behind Config.enableMMU.
//
// !!! KNOWN FOLLOW-UP — WHY Config.enableMMU STAYS FALSE FOR v1 !!!
// Once the MMU is on, RAM accesses are cacheable and the CPU's data cache
// is no longer coherent with DMA devices. The current drivers were written
// for the MMU-off world where every store reaches the device immediately:
//   - ramfb framebuffer: guest CPU writes pixels, QEMU/DMA reads them.
//     Dirty lines sitting in the D-cache mean a stale/tearing display
//     until the lines happen to evict. Needs a cache CLEAN of the
//     framebuffer (or a non-cacheable/device mapping for it) per flush.
//   - virtio-mmio rings (descriptor table, avail/used rings): bidirectional
//     DMA. Driver writes need a CLEAN before kicking the device; memory the
//     device wrote (used ring, rx buffers) needs an INVALIDATE before the
//     CPU reads it, or the CPU consumes stale cached lines.
// The stage-2 follow-up task: add cache clean/invalidate helpers (dc cvac /
// dc ivac by VA range) to MMU.S + MMU.swift, wire them into the ramfb and
// virtio drivers (or remap those buffers non-cacheable once fine-grained
// 4 KiB/2 MiB mappings exist), and only then flip Config.enableMMU.
// ============================================================================

@_silgen_name("mmu_read_id_aa64mmfr0") private func mmuReadIDMMFR0() -> UInt64
@_silgen_name("mmu_write_mair")        private func mmuWriteMAIR(_ v: UInt64)
@_silgen_name("mmu_write_tcr")         private func mmuWriteTCR(_ v: UInt64)
@_silgen_name("mmu_write_ttbr0")       private func mmuWriteTTBR0(_ v: UInt64)
@_silgen_name("mmu_read_sctlr")        private func mmuReadSCTLR() -> UInt64
@_silgen_name("mmu_write_sctlr")       private func mmuWriteSCTLR(_ v: UInt64)
@_silgen_name("mmu_tlbi_vmalle1")      private func mmuTLBIAll()

enum MMU {
    // MAIR_EL1: attr0 = 0x04 (device-nGnRnE), attr1 = 0xFF (normal,
    // inner+outer write-back, read/write allocate).
    private static let mairValue: UInt64 = 0x04 | (0xFF << 8)

    // TCR_EL1 fields (combined value = 0x2_0080_3518):
    private static let tcrT0SZ:  UInt64 = 24        // 40-bit VA (see header)
    private static let tcrIRGN0: UInt64 = 1 << 8    // inner WB RA/WA
    private static let tcrORGN0: UInt64 = 1 << 10   // outer WB RA/WA
    private static let tcrSH0:   UInt64 = 3 << 12   // inner shareable
    // TG0 = 0b00 (4 KiB granule) needs no bits set.
    private static let tcrEPD1:  UInt64 = 1 << 23   // never walk TTBR1
    private static let tcrIPS:   UInt64 = 2 << 32   // 40-bit PA (1 TB)
    private static let tcrValue: UInt64 =
        tcrT0SZ | tcrIRGN0 | tcrORGN0 | tcrSH0 | tcrEPD1 | tcrIPS

    // Descriptor field bits.
    private static let descBlock: UInt64 = 0b01       // valid block entry
    private static let descTable: UInt64 = 0b11       // valid table entry
    private static let attrIndx1: UInt64 = 1 << 2     // MAIR slot 1
    private static let apEL0:     UInt64 = 1 << 6     // AP[1]: RW at EL0 too
    private static let shInner:   UInt64 = 3 << 8     // inner shareable
    private static let af:        UInt64 = 1 << 10    // access flag
    private static let pxn:       UInt64 = 1 << 53    // never execute at EL1
    private static let uxn:       UInt64 = 1 << 54    // never execute at EL0

    /// L2 table covering the RAM gigabyte [0x4000_0000, 0x8000_0000), built
    /// by initMMU. 0 when the MMU was never initialized (MMU off): allowEL0
    /// is then a no-op — with translation disabled there are no permission
    /// checks for EL0 to trip over anyway.
    private static var l2RAM: UInt = 0

    /// Build the identity map and enable the MMU + I/D caches.
    /// On any sanity failure: log, leave the MMU off, return false.
    static func initMMU() -> Bool {
        // Sanity: 4 KiB granule supported, at least 40-bit physical addresses.
        let mmfr0 = mmuReadIDMMFR0()
        guard (mmfr0 >> 28) & 0xF == 0 else {      // ID_AA64MMFR0_EL1.TGran4
            klog("[mmu] 4 KiB granule unsupported, MMU stays off")
            return false
        }
        guard mmfr0 & 0xF >= 2 else {              // ID_AA64MMFR0_EL1.PARange
            klog("[mmu] PA range below 40 bits, MMU stays off")
            return false
        }

        guard let l0 = KernelHeap.allocPages(1), let l1 = KernelHeap.allocPages(1),
              let l2 = KernelHeap.allocPages(1),
              l0 & 0xFFF == 0, l1 & 0xFFF == 0, l2 & 0xFFF == 0 else {
            klog("[mmu] page table allocation failed, MMU stays off")
            return false
        }
        zeroPage(l0)
        zeroPage(l1)
        zeroPage(l2)

        // L0[0] -> L1.
        putDesc(l0, 0, UInt64(l1) | descTable)
        // L1[0]: [0x0000_0000, 0x4000_0000) device-nGnRnE (MAIR attr0),
        // execute-never at both ELs.
        putDesc(l1, 0, 0x0000_0000 | pxn | uxn | af | descBlock)
        // L2: 512 x 2 MiB blocks spanning [0x4000_0000, 0x8000_0000), normal
        // WB (MAIR attr1), inner shareable, EL1-only RW — the same mapping
        // the old 1 GiB L1 block produced, just split so allowEL0 can later
        // relax single slots. All 512 MiB of RAM [0x4000_0000, 0x6000_0000)
        // included.
        var slot = 0
        while slot < 512 {
            let pa = UInt64(0x4000_0000) &+ (UInt64(slot) << 21)
            putDesc(l2, slot, pa | af | shInner | attrIndx1 | descBlock)
            slot &+= 1
        }
        // L1[1] -> L2 table.
        putDesc(l1, 1, UInt64(l2) | descTable)
        l2RAM = l2

        // Program the translation regime before enabling it.
        mmuWriteMAIR(mairValue)
        mmuWriteTCR(tcrValue)
        mmuWriteTTBR0(UInt64(l0))
        armDsbSy()
        armIsb()

        // Enable M (MMU) | C (D-cache) | I (I-cache). Read-modify-write via
        // MRS preserves the RES1 bits in SCTLR_EL1.
        let sctlr = mmuReadSCTLR() | (1 << 0) | (1 << 2) | (1 << 12)
        mmuWriteSCTLR(sctlr)

        // Drop any stale TLB entries, then synchronize.
        mmuTLBIAll()
        armDsbSy()
        armIsb()

        guard mmuReadSCTLR() & 1 == 1 else {
            klog("[mmu] SCTLR.M did not stick, MMU stays off")
            return false
        }
        klog("[mmu] identity map on, caches enabled")
        return true
    }

    /// Open an EL0 window: mark every 2 MiB L2 slot covering
    /// [base, base+byteCount) readable/writable at EL0 as well as EL1
    /// (AP[1] set) and PXN (the kernel must never execute from a page EL0
    /// can write). UXN stays clear so the slot can hold user code.
    ///
    /// Stage-1 granularity caveat (documented stage-2 = per-4 KiB user
    /// maps): the WHOLE 2 MiB slot becomes EL0-accessible, including any
    /// neighbouring heap pages allocPages hands out in it. The EL0 demo
    /// blob is trusted demo code; do not run hostile binaries with this
    /// mapping scheme.
    ///
    /// No-op when the MMU was never initialized (l2RAM == 0): with
    /// translation off, EL0 accesses are unchecked anyway.
    static func allowEL0(base: UInt, byteCount: UInt) {
        guard l2RAM != 0, byteCount > 0 else { return }
        let ramBase: UInt = 0x4000_0000
        let ramEnd:  UInt = 0x8000_0000     // end of the mapped gigabyte
        guard base >= ramBase, base < ramEnd, byteCount <= ramEnd - base else {
            kpanic("mmu: allowEL0 range outside the RAM map")
        }
        let first = Int((base - ramBase) >> 21)
        let last  = Int((base + byteCount - 1 - ramBase) >> 21)
        var i = first
        while i <= last {
            let entry = l2RAM + UInt(i) * 8
            let desc = UnsafeMutablePointer<UInt64>(bitPattern: entry)!
            desc.pointee = desc.pointee | apEL0 | pxn
            i &+= 1
        }
        // The window may already be cached in the TLB (heap pages get
        // touched before the first EL0 run): flush and synchronize.
        mmuTLBIAll()
        armDsbSy()
        armIsb()
        kprint("[mmu] EL0 window: ")
        kprintHex(UInt64(base))
        kprint(" .. ")
        kprintHex(UInt64(base + byteCount))
        kprint(" (2 MiB-slot granularity)\n")
    }

    private static func zeroPage(_ base: UInt) {
        let p = UnsafeMutableRawPointer(bitPattern: base)!
        var off = 0
        while off < 4096 {
            p.storeBytes(of: UInt64(0), toByteOffset: off, as: UInt64.self)
            off += 8
        }
    }

    private static func putDesc(_ table: UInt, _ index: Int, _ desc: UInt64) {
        UnsafeMutableRawPointer(bitPattern: table)!
            .storeBytes(of: desc, toByteOffset: index &* 8, as: UInt64.self)
    }
}
