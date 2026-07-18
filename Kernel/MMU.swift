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
//     L1[1..8] -> L2 tables (8 GiB of RAM, one per gigabyte)
//              device-nGnRnE (MAIR attr0), PXN — UART, GIC, virtio-mmio
//     L1[1]  -> L2 table (the RAM gigabyte, split into 2 MiB slots so a
//              slot hosting EL0 pages can later be refined to 4 KiB
//              granularity — see allowEL0 below)
//     L1[9]  -> the core's ACTIVE scheduled-user-process L2 (per-core —
//              see "per-core roots" below; invalid while a kernel thread
//              runs on the core). This is the ONLY per-core entry.
//     rest   = invalid
//   L2 (1 page, 512 entries):
//     L2[i]  = 2 MiB block [0x4000_0000 + i*2MiB, +2MiB)
//              normal inner+outer write-back cacheable, inner shareable
//              (MAIR attr1), EL1-only RW — covers all 512 MiB of RAM plus
//              kernel/heap. Identical attrs to the former 1 GiB L1 block:
//              same translation, one extra walk level.
//   Per-core roots: cpu 0 runs on the boot L0/L1; each secondary gets a
//     clone (L0[0] -> private L1 copy, installed via useCoreTables from
//     Scheduler.runCore) so that L1[userSlot] — the scheduled user
//     process's private L2 — is PER-CORE. That is what lets two different
//     EL0 processes run simultaneously on two cores: same user VAs,
//     different physical pages, no shared-table contention. See the
//     perCoreL0 docs and Kernel/Userspace.swift.
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
    private static let ramEnd:  UInt = 0x2_4000_0000 // end of the mapped RAM (8 GiB)

    /// L2 tables covering the 8 RAM gigabytes [0x4000_0000, 0x2_4000_0000)
    /// (one 512-slot table per gigabyte), built by initMMU. Entry 0 is 0 when
    /// the MMU was never initialized (MMU off): allowEL0 is then a no-op —
    /// with translation disabled there are no permission checks for EL0 to
    /// trip over anyway.
    private static var l2Tables = [UInt](repeating: 0, count: 8)

    // MARK: Scheduled user processes (per-core user maps)
    //
    // L1 slot dedicated to the EL0 user window of the SCHEDULED user
    // process currently running on each core (UserProcess.spawn — see
    // Kernel/Userspace.swift; the legacy synchronous runDemo keeps using
    // identity-mapped pages via allowEL0 and never touches this slot).
    // Every user process shares one VA layout — blob at userWinBase, stack
    // page at userWinBase+4 KiB — and gets its own private L2 table
    // holding exactly those mappings, so the same VAs name different
    // physical pages for different processes. With 8 GiB of RAM mapped in
    // L1[1..8], slot 9 (9 GiB, 0x2_4000_0000) is the first free one.
    static let userSlot = 9
    static let userWinBase: UInt = 0x2_4000_0000     // userSlot GiB
    /// Per-process window span: one blob page + one stack page (4 KiB each).
    static let userWinSpan: UInt = 8192

    /// Per-core page-table roots, pre-built on the BSP in initMMU (no
    /// lazy-static first touch from secondaries). Entry 0 is the boot
    /// L0/L1 pair itself; entries 1..cpuCount-1 are clones: L0[0] -> a
    /// private L1 whose entries copy the BSP's (device block + pointers to
    /// the SAME shared RAM L2 tables — kernel translations are identical
    /// on every core, and later kernel-L2 slot splits via allowEL0 are
    /// seen by all) except L1[userSlot], which is PER-CORE: it points at
    /// the L2 table of the user process currently scheduled on that core
    /// (invalid while a kernel thread runs). Per-core L1s are what allow
    /// two different user processes at EL0 SIMULTANEOUSLY on two cores —
    /// a single shared L1 could hold only one core's user map. Secondaries
    /// install their pair via useCoreTables (from Scheduler.runCore);
    /// switchUserMap flips the per-core user slot on thread switches.
    private static var perCoreL0 = [UInt](repeating: 0, count: Config.cpuCount)
    private static var perCoreL1 = [UInt](repeating: 0, count: Config.cpuCount)

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
        // L1[0]: [0x0000_0000, 0x4000_0000) device-nGnRnE (MAIR attr0),
        // execute-never at both ELs.
        putDesc(l1, 0, 0x0000_0000 | pxn | uxn | af | descBlock)
        // L1[1...8]: 8 GiB of RAM [0x4000_0000, 0x2_4000_0000), one L2 table
        // per gigabyte, 512 x 2 MiB blocks each, normal WB (MAIR attr1),
        // inner shareable, EL1-only RW — extended for the Pi 5's 8 GiB and
        // kept slot-splittable so allowEL0 can relax single 2 MiB slots.
        var gb = 0
        while gb < 8 {
            guard let l2 = KernelHeap.allocPages(1), l2 & 0xFFF == 0 else {
                klog("[mmu] page table allocation failed, MMU stays off")
                return false
            }
            zeroPage(l2)
            var slot = 0
            while slot < 512 {
                let pa = (UInt64(gb &+ 1) << 30) &+ (UInt64(slot) << 21)
                putDesc(l2, slot, pa | af | shInner | attrIndx1 | descBlock)
                slot &+= 1
            }
            putDesc(l1, gb + 1, UInt64(l2) | descTable)
            l2Tables[gb] = l2
            gb &+= 1
        }

        // Per-core roots (see the perCoreL0 docs above): cpu 0 keeps the
        // boot pair; every secondary gets a clone. Built here, on the BSP —
        // secondaries only write TTBR0 (useCoreTables), they never allocate
        // or first-touch these statics. A clone's L1 copies the BSP's
        // wholesale, so it sees the device block and the same shared RAM L2
        // tables; L1[userSlot] stays zero (no user map) until that core
        // schedules a user thread.
        perCoreL0[0] = l0
        perCoreL1[0] = l1
        var cpu = 1
        while cpu < Config.cpuCount {
            guard let cl0 = KernelHeap.allocPages(1), let cl1 = KernelHeap.allocPages(1),
                  cl0 & 0xFFF == 0, cl1 & 0xFFF == 0 else {
                klog("[mmu] per-core table allocation failed, MMU stays off")
                return false
            }
            zeroPage(cl0)
            var e = 0
            while e < 512 {
                putDesc(cl1, e, loadDesc(l1, e))
                e &+= 1
            }
            putDesc(cl0, 0, UInt64(cl1) | descTable)
            perCoreL0[cpu] = cl0
            perCoreL1[cpu] = cl1
            cpu &+= 1
        }

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
    /// No-op when the MMU was never initialized (l2Tables[0] == 0): with
    /// translation off, EL0 accesses are unchecked anyway.
    static func allowEL0(base: UInt, byteCount: UInt) {
        guard l2Tables[0] != 0 else { return }
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

    // MARK: - Scheduled user processes: per-core user maps

    /// True when the MMU was initialized (identity map live). Scheduled
    /// user processes REQUIRE it: their code runs at userWinBase VAs that
    /// exist only inside per-process L2 windows — with translation off
    /// those addresses are beyond the RAM map entirely.
    static var isOn: Bool { l2Tables[0] != 0 }

    /// Point this core's TTBR0_EL1 at its private L0/L1 pair (pre-built in
    /// initMMU). Secondaries call this once from Scheduler.runCore, after
    /// the SMP bring-up replayed the BSP's translation sysregs; the private
    /// L1 duplicates every kernel mapping, so the switch changes no
    /// translation — it only gives the core its own L1[userSlot] to flip
    /// when it later schedules user threads. Allocation- and lock-free
    /// (tables pre-built, sysreg writes only): safe from any context.
    /// No-op for unknown cpus or when the MMU was never initialized.
    static func useCoreTables(cpu: Int) {
        guard cpu >= 0, cpu < Config.cpuCount else { return }
        let root = perCoreL0[cpu]
        guard root != 0 else { return }
        mmuWriteTTBR0(UInt64(root))
        syncTables()
    }

    /// Install (or clear) this core's active user map: point L1[userSlot]
    /// of the core's private L1 at the given per-process L2 table, or make
    /// it invalid when `l2` is 0 (kernel thread current). Then flush this
    /// core's TLB — load-bearing for isolation, not hygiene: stale entries
    /// for the user window could otherwise keep translating a previous
    /// process's VAs to pages that were freed and reused by someone else.
    /// Per-core state only (the write touches no shared table, and
    /// tlbi vmalle1 is local to this core), so concurrent installs on
    /// other cores are unaffected. Allocation-free, takes no locks: legal
    /// from the scheduler's switch path (Locks.sched held, IRQ context).
    static func switchUserMap(cpu: Int, l2: UInt) {
        guard cpu >= 0, cpu < Config.cpuCount else { return }
        let l1 = perCoreL1[cpu]
        guard l1 != 0 else { return }
        putDesc(l1, userSlot, l2 != 0 ? (UInt64(l2) | descTable) : 0)
        syncTables()
    }

    /// Build a per-process user map in two caller-supplied, already-zeroed
    /// pages: `l2` gets a single table descriptor at slot 0 pointing at
    /// `l3`; `l3` maps exactly two 4 KiB pages at the bottom of the user
    /// window — page 0 = blobPA (code + data: EL0+EL1 RW, PXN so the
    /// kernel can never execute a user-writable page, UXN clear so EL0
    /// can), page 1 = stackPA (same, plus UXN: the stack is never code).
    /// Every other entry stays invalid, so any EL0 access outside its two
    /// pages is a translation fault contained as a user-program fault.
    /// No TLB maintenance here: nothing has ever walked these VAs through
    /// this table; the installing switchUserMap flushes. Pure descriptor
    /// writes — allocation- and lock-free.
    static func makeUserMap(l2: UInt, l3: UInt, blobPA: UInt, stackPA: UInt) {
        putDesc(l2, 0, UInt64(l3) | descTable)
        putDesc(l3, 0, UInt64(blobPA) | af | shInner | attrIndx1 | apEL0 | pxn | descPage)
        putDesc(l3, 1, UInt64(stackPA) | af | shInner | attrIndx1 | apEL0 | pxn | uxn | descPage)
    }

    /// Split slot `slot` of the RAM L2 table into 512 x 4 KiB L3 pages and
    /// return the L3 table address (nil on allocation failure — the slot is
    /// then left as its original block). Idempotent: an already-split slot
    /// returns its existing table.
    private static func ensureL3Table(slot: Int) -> UInt? {
        guard slot >= 0, slot < 4096 else { return nil }
        let l2 = l2Tables[slot >> 9]
        let entry = UnsafeMutablePointer<UInt64>(bitPattern: l2 + UInt(slot & 511) * 8)!
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
        let l2e = loadDesc(l2Tables[slot >> 9], slot & 511)
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
        putDesc(l2Tables[slot >> 9], slot & 511, blockDesc)
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
