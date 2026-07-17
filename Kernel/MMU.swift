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
//     L1[1]  = 1 GiB block [0x4000_0000, 0x8000_0000)
//              normal inner+outer write-back cacheable, inner shareable
//              (MAIR attr1) — covers all 512 MiB of RAM plus kernel/heap
//     rest   = invalid
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

    // TCR_EL1: T0SZ=24 (see header) | IRGN0=0b01 WB | ORGN0=0b01 WB |
    // SH0=0b11 inner-shareable | TG0=0b00 (4 KiB) | EPD1=1 (never walk
    // TTBR1) | IPS=0b010 (40-bit PA).  = 0x2_0080_3518
    private static let tcrValue: UInt64 =
        24 | (1 << 8) | (1 << 10) | (3 << 12) | (1 << 23) | (2 << 32)

    // Descriptor field bits.
    private static let descBlock: UInt64 = 0b01       // valid block entry
    private static let descTable: UInt64 = 0b11       // valid table entry
    private static let attrIndx1: UInt64 = 1 << 2     // MAIR slot 1
    private static let shInner:   UInt64 = 3 << 8     // inner shareable
    private static let af:        UInt64 = 1 << 10    // access flag
    private static let pxn:       UInt64 = 1 << 54    // never execute at EL1

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
              l0 & 0xFFF == 0, l1 & 0xFFF == 0 else {
            klog("[mmu] page table allocation failed, MMU stays off")
            return false
        }
        zeroPage(l0)
        zeroPage(l1)

        // L0[0] -> L1.
        putDesc(l0, 0, UInt64(l1) | descTable)
        // L1[0]: [0x0000_0000, 0x4000_0000) device-nGnRnE (MAIR attr0), PXN.
        putDesc(l1, 0, 0x0000_0000 | pxn | af | descBlock)
        // L1[1]: [0x4000_0000, 0x8000_0000) normal WB (MAIR attr1), inner
        // shareable — all 512 MiB of RAM [0x4000_0000, 0x6000_0000) included.
        putDesc(l1, 1, 0x4000_0000 | af | shInner | attrIndx1 | descBlock)

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
