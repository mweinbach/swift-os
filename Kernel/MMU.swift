// ============================================================================
// MMU — stage-1 address translation for EL1 (AArch64, 4 KiB granule).
//
// Identity map: virtual address == physical address everywhere, TTBR0_EL1
// only, no ASIDs (all entries global). Table pages are allocated from
// KernelHeap and never freed — they must live forever:
//
//   L0 (1 page, zeroed):
//     L0[0]  -> L1 table
//   L1 (1 page, zeroed):
//     L1[0]  = 1 GiB block [0x0000_0000, 0x4000_0000)
//              device-nGnRnE (MAIR attr0), PXN — UART, GIC, virtio-mmio
//     L1[1]  -> L2 table (the RAM gigabyte, split into 2 MiB slots so a
//              slot hosting EL0 pages can later be refined to 4 KiB
//              granularity — see allowEL0 below)
//     rest   = invalid
//   L2 (1 page, 512 entries):
//     L2[i]  = 2 MiB block [0x4000_0000 + i*2MiB, +2MiB)
//              normal inner+outer write-back cacheable, inner shareable
//              (MAIR attr1), EL1-only RW — covers all 512 MiB of RAM plus
//              kernel/heap. Identical attrs to the former 1 GiB L1 block:
//              same translation, one extra walk level.
//   L3 (1 page, allocated on demand — one per L2 slot that hosts EL0 pages):
//     allowEL0 replaces the slot's L2 block descriptor with a pointer to a
//     fresh L3 table holding 512 x 4 KiB page descriptors that inherit the
//     slot's RAM attributes and default to EL1-only. Only the pages actually
//     handed to user code are flipped EL0-accessible; neighbouring heap
//     pages in the same 2 MiB slot stay EL1-only, so an EL0 access to them
//     raises a level-3 permission fault (contained by UserProcess as a user
//     fault) instead of the stage-1 scheme's silent read/write of whatever
//     kernel data shared the slot.
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
    private static let descPage:  UInt64 = 0b11       // valid L3 page entry
    private static let attrIndx1: UInt64 = 1 << 2     // MAIR slot 1
    private static let apEL0:     UInt64 = 1 << 6     // AP[1]: RW at EL0 too
    private static let shInner:   UInt64 = 3 << 8     // inner shareable
    private static let af:        UInt64 = 1 << 10    // access flag
    private static let pxn:       UInt64 = 1 << 53    // never execute at EL1
    private static let uxn:       UInt64 = 1 << 54    // never execute at EL0
    private static let paMask:    UInt64 = 0x0000_FFFF_FFFF_F000

    private static let ramBase: UInt = 0x4000_0000
    private static let ramEnd:  UInt = 0x8000_0000   // end of the mapped gigabyte

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
        if selfTest() {
            klog("[mmu] self-test ok")
        } else {
            // Diagnostic only — every fetch/load since SCTLR.M was set went
            // through the live map already, so boot continues (see selfTest).
            klog("[mmu] SELF-TEST FAILED — booting on anyway (see above)")
        }
        return true
    }

    /// Open an EL0 window over exactly the 4 KiB pages covering
    /// [base, base+byteCount): those pages become EL0+EL1 read/write with
    /// PXN set (the kernel must never execute from a page EL0 can write)
    /// and UXN clear, so the window can hold user code. Every other page in
    /// the affected 2 MiB slot(s) keeps its EL1-only mapping — unlike the
    /// stage-1 scheme, neighbouring heap pages are NOT exposed; an EL0
    /// access to them raises a level-3 permission fault, contained by
    /// UserProcess as a user-program fault.
    ///
    /// The first window in a slot replaces its L2 block descriptor with a
    /// pointer to a fresh L3 table (one KernelHeap page, never freed) whose
    /// 512 entries inherit the slot's attributes at 4 KiB granularity;
    /// later windows in the same slot reuse the table.
    ///
    /// Arguments are validated and refused gracefully (log + return, no
    /// mapping change): byteCount must be nonzero, base must be 4 KiB-aligned,
    /// and the whole range must lie inside the mapped RAM gigabyte. A range
    /// spanning several 2 MiB slots is supported — each slot gets its own
    /// L3 table, each page run is capped to its slot.
    ///
    /// No-op when the MMU was never initialized (l2RAM == 0): with
    /// translation off, EL0 accesses are unchecked anyway.
    static func allowEL0(base: UInt, byteCount: UInt) {
        guard l2RAM != 0 else { return }
        guard byteCount > 0 else {
            klog("[mmu] allowEL0: zero length refused")
            return
        }
        guard base & 0xFFF == 0 else {
            klog("[mmu] allowEL0: unaligned base refused")
            return
        }
        guard base >= ramBase, base < ramEnd, byteCount <= ramEnd - base else {
            klog("[mmu] allowEL0: range outside the RAM map refused")
            return
        }

        let last = base + byteCount - 1
        var slot = Int((base - ramBase) >> 21)
        let lastSlot = Int((last - ramBase) >> 21)
        while slot <= lastSlot {
            guard let l3 = ensureL3Table(slot: slot) else {
                klog("[mmu] allowEL0: L3 allocation failed — window refused")
                return
            }
            // Covering 4 KiB pages inside this slot, capped to the slot.
            let slotBase = ramBase &+ (UInt(slot) << 21)
            let slotLast = slotBase &+ 0x1F_FFFF
            let lo = base > slotBase ? base : slotBase
            let hi = last < slotLast ? last : slotLast
            var idx = Int((lo - slotBase) >> 12)
            let idxEnd = Int((hi - slotBase) >> 12)
            while idx <= idxEnd {
                let e = UnsafeMutablePointer<UInt64>(bitPattern: l3 + UInt(idx) * 8)!
                e.pointee = e.pointee | apEL0 | pxn
                idx &+= 1
            }
            slot &+= 1
        }
        // The window may already be cached in the TLB (heap pages get
        // touched before the first EL0 run): flush and synchronize.
        syncTables()
        kprint("[mmu] EL0 window: ")
        kprintHex(UInt64(base))
        kprint(" .. ")
        kprintHex(UInt64(base + byteCount))
        kprint(" (4 KiB page granularity)\n")
    }

    /// Split slot `slot` of the RAM L2 table into 512 x 4 KiB L3 pages and
    /// return the L3 table address (nil on allocation failure — the slot is
    /// then left as its original block). Idempotent: an already-split slot
    /// returns its existing table.
    private static func ensureL3Table(slot: Int) -> UInt? {
        let entry = UnsafeMutablePointer<UInt64>(bitPattern: l2RAM + UInt(slot) * 8)!
        let cur = entry.pointee
        if cur & 0b11 == descTable {
            return UInt(cur & paMask)            // already split
        }
        guard let l3 = KernelHeap.allocPages(1), l3 & 0xFFF == 0 else {
            return nil
        }
        // Fill before publishing: every entry inherits the slot's block
        // attributes (normal WB cacheable, inner shareable, EL1-only RW) at
        // 4 KiB granularity, so the split alone changes no translation.
        let slotPA = UInt64(ramBase) &+ (UInt64(slot) << 21)
        var i = 0
        while i < 512 {
            putDesc(l3, i, (slotPA &+ (UInt64(i) << 12)) | af | shInner | attrIndx1 | descPage)
            i &+= 1
        }
        // Publish. Until the caller's syncTables() invalidates them, stale
        // 2 MiB block TLB entries keep serving EL1 with the identical
        // translation — the only consumer in between — so the make-then-break
        // order is safe here (and a walk that does miss sees a complete L3,
        // since it was fully written before the pointer).
        entry.pointee = UInt64(l3) | descTable
        return l3
    }

    /// Make descriptor stores visible to the table walker, drop stale TLB
    /// entries (a slot's old 2 MiB block entry may be cached from before its
    /// split), wait for the maintenance to complete, and synchronize the
    /// instruction stream.
    private static func syncTables() {
        armDsbSy()
        mmuTLBIAll()
        armDsbSy()
        armIsb()
    }

    /// Boot-time sanity check, run once at the end of initMMU with the MMU
    /// already on. Diagnostic only: failures are logged and boot continues —
    /// every fetch/load since SCTLR.M was set already went through the live
    /// map, so a failed probe says more about the probe than the map.
    /// Checks: (1) normal-RAM translation round-trip through a fresh heap
    /// page, (2) the device block still does MMIO (GICD_TYPER probe read),
    /// (3) the L3 machinery: split the scratch page's slot exactly the way
    /// allowEL0 does, verify the L2/L3 descriptor bits and the per-page EL0
    /// marking, verify EL1 translation through the split slot, then revert
    /// the slot to its pristine 2 MiB block and free everything touched.
    private static func selfTest() -> Bool {
        guard let scratch = KernelHeap.allocPages(1) else {
            klog("[mmu] self-test: no scratch page")
            return false
        }
        var ok = true

        // 1. Translation round-trip: store/load via VA in identity-mapped RAM.
        let p0 = UnsafeMutablePointer<UInt64>(bitPattern: scratch)!
        let p1 = UnsafeMutablePointer<UInt64>(bitPattern: scratch + 2048)!
        p0.pointee = 0x5A5A_A5A5_3C3C_C3C3
        p1.pointee = 0x0F1E_2D3C_4B5A_6978
        if p0.pointee != 0x5A5A_A5A5_3C3C_C3C3 || p1.pointee != 0x0F1E_2D3C_4B5A_6978 {
            klog("[mmu] self-test: RAM VA write/read mismatch")
            ok = false
        }

        // 2. Device-block probe: GICD_TYPER (0x0800_0008) lives in the
        //    device-nGnRnE gigabyte. A sane read proves MMIO works post-MMU
        //    (a broken device block would data-abort here instead); 0 and
        //    all-ones are how a dead or unmapped bus answers.
        let typer = mmioRead32(0x0800_0008)
        if typer == 0 || typer == 0xFFFF_FFFF {
            klog("[mmu] self-test: GICD probe read garbage")
            ok = false
        }

        // 3. L3 split + per-page EL0 marking on the scratch page's slot.
        let slot = Int((scratch - ramBase) >> 21)
        let slotPA = UInt64(ramBase) &+ (UInt64(slot) << 21)
        let blockDesc = slotPA | af | shInner | attrIndx1 | descBlock
        guard let l3 = ensureL3Table(slot: slot) else {
            klog("[mmu] self-test: L3 table allocation failed")
            KernelHeap.freePages(scratch, count: 1)
            return false
        }
        // The L2 entry must now be a table descriptor pointing at the L3 page.
        let l2e = loadDesc(l2RAM, slot)
        if l2e & 0b11 != descTable || l2e & paMask != UInt64(l3) {
            klog("[mmu] self-test: L2 entry is not the installed L3 table")
            ok = false
        }
        // Default L3 entries inherit the slot's block attrs, EL1-only.
        let idx = Int(((scratch - ramBase) & 0x1F_FFFF) >> 12)
        let defaultDesc = UInt64(scratch) | af | shInner | attrIndx1 | descPage
        if loadDesc(l3, idx) != defaultDesc {
            klog("[mmu] self-test: L3 default entry mismatch")
            ok = false
        }
        // Mark the scratch page the way allowEL0 does: AP[1] + PXN. The
        // neighbour page must keep its EL1-only mapping.
        let nIdx = idx == 511 ? 510 : idx + 1
        let nDesc = (slotPA &+ (UInt64(nIdx) << 12)) | af | shInner | attrIndx1 | descPage
        putDesc(l3, idx, defaultDesc | apEL0 | pxn)
        if loadDesc(l3, idx) != defaultDesc | apEL0 | pxn {
            klog("[mmu] self-test: EL0 page bits mismatch")
            ok = false
        }
        if loadDesc(l3, nIdx) != nDesc {
            klog("[mmu] self-test: neighbour page lost its EL1-only mapping")
            ok = false
        }
        // EL1 translation through the split (and EL0-marked) page is intact.
        p0.pointee = 0xC3C3_3C3C_A5A5_5A5A
        if p0.pointee != 0xC3C3_3C3C_A5A5_5A5A {
            klog("[mmu] self-test: translation broken after slot split")
            ok = false
        }

        // Revert to the pristine block mapping; free everything touched.
        putDesc(l2RAM, slot, blockDesc)
        syncTables()
        KernelHeap.freePages(l3, count: 1)
        KernelHeap.freePages(scratch, count: 1)
        return ok
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

    private static func loadDesc(_ table: UInt, _ index: Int) -> UInt64 {
        UnsafeRawPointer(bitPattern: table)!
            .load(fromByteOffset: index &* 8, as: UInt64.self)
    }
}
