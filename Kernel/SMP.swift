// SMP bring-up for the Pi-5-profile 4-core machine.
//
// Secondaries are real scheduling cores: each comes online via PSCI CPU_ON
// (per-core FP/SIMD enable in SMP.S), JOINS THE BSP'S TRANSLATION REGIME
// (joinBSPTranslationRegime — PSCI starts secondaries with the MMU off,
// where memory is device-like and unaligned accesses fault), prints a
// spinlock-guarded line, runs its per-core interrupt bring-up
// (Interrupts.initCoreInterrupts — banked GICC/GICD state, vectors, local
// 100 Hz tick), and enters the scheduler's per-core run loop
// (Scheduler.runCore(cpu:) — Never).

@_silgen_name("arm_spin_lock") func armSpinLock(_ lock: UInt)
@_silgen_name("arm_spin_unlock") func armSpinUnlock(_ lock: UInt)
@_silgen_name("arm_klog_lock_addr") func armKlogLockAddr() -> UInt
@_silgen_name("arm_smp_entry_addr") private func armSmpEntryAddr() -> UInt
@_silgen_name("arm_psci_call") private func armPsciCall2(_ function: UInt32, _ arg1: UInt, _ arg2: UInt, _ arg3: UInt) -> UInt

// Per-core MMU join: the BSP captures its LIVE translation config (read
// side below, in SMP.S); secondaries replay it (write side: the global
// helpers already exported by Kernel/MMU.S).
@_silgen_name("arm_read_mair")  private func armReadMair() -> UInt64
@_silgen_name("arm_read_tcr")   private func armReadTcr() -> UInt64
@_silgen_name("arm_read_ttbr0") private func armReadTtbr0() -> UInt64
@_silgen_name("mmu_read_sctlr") private func mmuReadSCTLR() -> UInt64
@_silgen_name("mmu_write_mair")  private func mmuWriteMair(_ v: UInt64)
@_silgen_name("mmu_write_tcr")   private func mmuWriteTcr(_ v: UInt64)
@_silgen_name("mmu_write_ttbr0") private func mmuWriteTtbr0(_ v: UInt64)
@_silgen_name("mmu_write_sctlr") private func mmuWriteSctlr(_ v: UInt64)
@_silgen_name("mmu_tlbi_vmalle1") private func mmuTLBIAll()

enum SMP {
    /// The BSP's live translation config, captured in startSecondaries()
    /// (which kmain calls only AFTER MMU.initMMU) and replayed by every
    /// secondary at the very top of smpSecondaryMain. Capturing the live
    /// registers — instead of restating constants — means this can never
    /// drift from whatever MMU.initMMU actually programmed. First touch is
    /// on the BSP (lazy-static rule); secondaries only read.
    private static var bspMair: UInt64 = 0
    private static var bspTcr: UInt64 = 0
    private static var bspTtbr0: UInt64 = 0
    private static var bspSctlr: UInt64 = 0

    /// Bring up secondary CPUs (1 ... Config.cpuCount-1) via PSCI CPU_ON.
    static func startSecondaries() {
        guard Config.smpEnabled else { return }

        // Capture the BSP's translation config for the secondaries' MMU
        // join (PSCI CPU_ON starts them with the MMU off).
        bspMair = armReadMair()
        bspTcr = armReadTcr()
        bspTtbr0 = armReadTtbr0()
        bspSctlr = mmuReadSCTLR()

        var cpu: UInt = 1
        while cpu < UInt(Config.cpuCount) {
            guard let stack = KernelHeap.allocPages(4) else {
                klog("[smp] stack allocation failed — secondary bring-up stopped")
                return
            }
            let ctx = stack + UInt(4 * 4096) - 16
            UnsafeMutablePointer<UInt64>(bitPattern: ctx)!.pointee = UInt64(cpu)
            let rc = armPsciCall2(0xC400_0003, cpu, armSmpEntryAddr(), ctx)
            if rc != 0 {
                klog("[smp] CPU_ON failed for cpu \(cpu) (rc=\(Int64(bitPattern: UInt64(rc))))")
            }
            cpu += 1
        }
    }

    /// Per-core MMU join (secondary side of the startSecondaries capture):
    /// program this core's MAIR/TCR/TTBR0/SCTLR with the BSP's live values,
    /// mirroring MMU.initMMU's enable sequence (translation regime first,
    /// SCTLR last, barriers around it). With the MMU off, memory is
    /// device-like and any UNALIGNED access faults (ESR 0x96000021 — the
    /// String/runtime slow paths do such accesses and died on secondaries).
    /// If the BSP runs with the MMU off (init failed or Config.enableMMU
    /// false), the replayed SCTLR simply keeps this core off too — same as
    /// the BSP. The page tables are shared and were built before CPU_ON, so
    /// this core's TLB starts empty; the tlbi is belt-and-braces.
    static func joinBSPTranslationRegime() {
        mmuWriteMair(bspMair)
        mmuWriteTcr(bspTcr)
        mmuWriteTtbr0(bspTtbr0)
        armDsbSy()
        armIsb()
        mmuWriteSctlr(bspSctlr)
        mmuTLBIAll()
        armDsbSy()
        armIsb()
    }
}

/// Secondary CPU entry (from asm): spinlock-guarded online line via the
/// *Unlocked UART helpers (the standalone kprint* functions take the klog
/// lock per call and would self-deadlock inside the held lock), per-core
/// interrupt bring-up, then the scheduler's per-core run loop (Never).
/// Scheduler.runCore logs its own per-core '[sched] cpu N online: idle
/// slot ...' line once it has adopted the core.
@_silgen_name("smp_secondary_main")
func smpSecondaryMain(_ cpu: UInt64) -> Never {
    // FIRST: join the BSP's translation regime. PSCI starts this core with
    // the MMU off; without this, the first unaligned memory access (the
    // String/runtime slow paths emit them) alignment-faults.
    SMP.joinBSPTranslationRegime()

    let lock = armKlogLockAddr()
    armSpinLock(lock)
    kprintUnlocked("[smp] cpu ")
    kprintDecUnlocked(Int64(cpu))
    kprintUnlocked(" online\n")
    armSpinUnlock(lock)

    // Per-core GIC CPU interface + banked SGI/PPI enables + vectors + the
    // local 100 Hz tick, then unmask IRQs on this core. The distributor's
    // global config was done by the BSP's initInterrupts().
    Interrupts.initCoreInterrupts(cpu: Int(cpu))

    // Per-core scheduling loop — pinned cross-agent API (owned by the
    // scheduler agent; landed in Kernel/Scheduler.swift). Never returns.
    Scheduler.runCore(cpu: Int(cpu))
}
