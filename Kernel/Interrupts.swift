// GICv2 + ARM generic timer: exception vectors, IRQ dispatch, 100 Hz tick.
// QEMU virt: GICD at 0x0800_0000, GICC at 0x0801_0000 — discovered from the
// device tree at boot (Machine.gicdBase/giccBase, Kernel/DTB.swift); those
// hardcoded values live on as the compiled-in defaults. The EL1 physical
// timer (CNTP_*) is PPI 30 (INTID 30); SPIs start at 32. SGI 1 is reserved
// as the panic-halt IPI (see Kernel/Panic.swift and the SGI-1 check in
// Vectors.S' irq_entry).
//
// SMP: initInterrupts() (BSP) does the one-time distributor global config,
// then both BSP and secondaries run initCoreInterrupts(cpu:) for the
// per-core parts — the GICC CPU interface is banked per core, and so are
// the SGI/PPI enables and priorities in GICD_ISENABLER0 / GICD_IPRIORITYR0-7,
// so every core must program its OWN bank to get its local 100 Hz tick.

@_silgen_name("arm_install_vectors") private func armInstallVectors()
@_silgen_name("arm_write_cntp_tval") private func armWriteCntpTval(_ value: UInt32)
@_silgen_name("arm_write_cntp_ctl")  private func armWriteCntpCtl(_ value: UInt32)
@_silgen_name("arm_read_mpidr")      private func armReadMpidr() -> UInt

enum Interrupts {
    /// Timer ticks since initInterrupts() (1 tick = 10 ms). Written ONLY by
    /// cpu 0's timer IRQ (see handleIrq): with per-core ticks on all cores,
    /// letting every core bump the shared counter would run uptime ~4x fast
    /// (and race). Secondaries' scheduler tick accounting is per-core inside
    /// Scheduler, not here.
    static private(set) var tickCount: UInt64 = 0

    /// GICv2 register map. Bases come from the device tree (Machine.*);
    /// the defaults are QEMU virt's 0x0800_0000 / 0x0801_0000.
    private enum GIC {
        static var distBase: UInt { Machine.gicdBase }
        static var cpuBase:  UInt { Machine.giccBase }

        static var dCtlr: UInt       { distBase + 0x000 }   // GICD_CTLR
        static var dISENABLER: UInt  { distBase + 0x100 }   // +4 per 32 interrupt IDs
        static var dIPRIORITYR: UInt { distBase + 0x400 }   // +4 per 4 IDs (byte fields)
        static var dITARGETSR: UInt  { distBase + 0x800 }   // +4 per 4 IDs, SPIs only

        static var cCtlr: UInt { cpuBase + 0x000 }          // GICC_CTLR
        static var cPMR: UInt  { cpuBase + 0x004 }          // GICC_PMR
        static var cEOIR: UInt { cpuBase + 0x010 }          // GICC_EOIR
    }

    /// EL1 physical timer PPI on the virt GIC.
    private static let timerIntid: UInt32 = 30
    /// Panic-halt IPI: SGI 1. Reserved kernel-wide — the same ID is baked
    /// into the Vectors.S irq_entry SGI check and the Panic broadcast.
    private static let panicHaltIntid: UInt32 = 1
    /// Tick rate.
    private static let ticksPerSecond: UInt64 = 100
    /// CNTP cycles per tick, derived from Clock.frequency.
    private static var ticksPerPeriod: UInt32 = 0

    /// Install the vector table, bring up the GIC, and start the 100 Hz
    /// timer tick. Call once from kmain (BSP only), after the heap is up.
    static func initInterrupts() {
        tickCount = 0
        initCoreInterrupts(cpu: 0)
        klog("[gic] timer irq \(timerIntid) at \(ticksPerSecond) Hz")
    }

    /// Per-core interrupt bring-up: vectors, GIC CPU interface, the banked
    /// SGI/PPI enables, and this core's local 100 Hz timer tick. cpu 0 (from
    /// initInterrupts) additionally does the one-time GICD global config;
    /// cpu > 0 (from the SMP secondary flow, smp_secondary_main) touches
    /// ONLY per-core state — the distributor's global configuration and SPI
    /// routing stay the BSP's.
    ///
    /// The GICC registers and the SGI/PPI (INTID 0-31) fields of
    /// GICD_ISENABLER0/GICD_IPRIORITYR0-7 are banked per core, and CNTP_* are
    /// per-core system registers, so this is safe — and required — on every
    /// core. VBAR_EL1 is per-core too: every core installs the SAME vector
    /// table address (identity mapped).
    static func initCoreInterrupts(cpu: Int) {
        // Same value on every core (Clock.frequency is set once by the BSP
        // before secondaries start); written unconditionally so this
        // function is self-sufficient on secondaries.
        ticksPerPeriod = UInt32(Clock.frequency / ticksPerSecond)

        armInstallVectors()

        if cpu == 0 {
            // One-time distributor global config: enable forwarding.
            mmioWrite32(GIC.dCtlr, 1)
        }

        // CPU interface (this core's bank): pass all priorities, enable
        // signaling.
        mmioWrite32(GIC.cPMR, 0xFF)
        mmioWrite32(GIC.cCtlr, 1)

        // Banked SGI/PPI setup for THIS core: priority of the timer PPI,
        // then enable the panic-halt SGI and the timer PPI in this core's
        // GICD_ISENABLER0 bank. (SGIs are always enabled in QEMU's GICv2
        // model, but the architecture allows them to be masked — set the
        // bit so the panic IPI works on real GICs too.)
        setPriority(timerIntid, 0xA0)
        enableInterrupt(panicHaltIntid)
        enableInterrupt(timerIntid)

        // Arm this core's first 10 ms tick: ENABLE with IMASK clear.
        armWriteCntpTval(ticksPerPeriod)
        armWriteCntpCtl(1)

        armDsbSy()
        armIsb()
        armIrqEnable()
    }

    /// Sleep until the next timer tick has fired. A wakeup from any other
    /// (or spurious) IRQ just sends us back to sleep, so this returns only
    /// after a real tick.
    static func waitForNextTick() {
        let target = tickCount &+ 1
        while tickCount < target {
            armWfi()
        }
    }

    /// Ticks since initInterrupts() at 100 Hz (1 tick = 10 ms).
    static func uptimeTicks() -> UInt64 { tickCount }

    /// GIC dispatch for the Vectors.S IRQ stub (via swift_irq_dispatch).
    /// IRQ CONTEXT: no allocation, no interpolation — counters + MMIO only.
    ///
    /// Runs on EVERY core now (each core has its own timer PPI). The shared
    /// uptime tickCount is bumped by cpu 0 only — otherwise uptime would run
    /// ~4x fast and the increments would race. Every core rearms its own
    /// CNTP and gets the Scheduler.onTimerTick hook (the scheduler keeps
    /// per-core run state; the hook is the pinned seam).
    ///
    /// The EOI comes BEFORE Scheduler.onTimerTick: the scheduler hook may
    /// context-switch, and while the timer PPI is still active (not EOI'd)
    /// the GIC will not re-signal it — deferring EOI until the preempted
    /// thread resumes would starve the tick, and the scheduler itself is
    /// driven by that tick. EOI first, then the (never-blocking) hook.
    fileprivate static func handleIrq(_ iar: UInt32) {
        let intid = iar & 0x3FF
        let cpu = armReadMpidr() & 0xFF
        if intid == timerIntid {
            if cpu == 0 {
                tickCount &+= 1                  // global uptime: BSP's tick only
            }
            armWriteCntpTval(ticksPerPeriod)    // this core's next 10 ms tick
        }
        mmioWrite32(GIC.cEOIR, iar)
        if intid == timerIntid {
            Scheduler.onTimerTick()             // may context-switch; no-op unless Config.enableScheduler
        }
    }

    /// Enable interrupt `id` in the distributor. PPIs are banked per-CPU;
    /// SPIs additionally get routed to CPU interface 0.
    private static func enableInterrupt(_ id: UInt32) {
        mmioWrite32(GIC.dISENABLER + UInt(id / 32) * 4, UInt32(1) << (id % 32))
        if id >= 32 {
            let reg = GIC.dITARGETSR + UInt(id / 4) * 4
            let shift = UInt32((id % 4) * 8)
            let v = (mmioRead32(reg) & ~(UInt32(0xFF) << shift)) | (UInt32(0x01) << shift)
            mmioWrite32(reg, v)
        }
    }

    /// Set the priority byte of interrupt `id`.
    private static func setPriority(_ id: UInt32, _ priority: UInt8) {
        let reg = GIC.dIPRIORITYR + UInt(id / 4) * 4
        let shift = UInt32((id % 4) * 8)
        let v = (mmioRead32(reg) & ~(UInt32(0xFF) << shift)) | (UInt32(priority) << shift)
        mmioWrite32(reg, v)
    }
}

// MARK: - Exception entry points (called from Vectors.S)

/// IRQ dispatch. Runs in IRQ context: MMIO and counters only, no allocation.
@_cdecl("swift_irq_dispatch")
func swiftIrqDispatch(_ iar: UInt32) {
    Interrupts.handleIrq(iar)
}

/// Fatal exception entry for the Vectors.S sync/FIQ/SError/unexpected-vector
/// stubs: full crash dump via Kernel/Panic.swift (serial + on-screen panic),
/// then halt. `regs` is the stub's 256-byte snapshot: [0...30] = x0...x30 at
/// the exception, [31] = the exception-time SP. kind: 0 = sync at EL1,
/// 1 = FIQ, 2 = SError, 3 = unexpected vector. (Synchronous exceptions from
/// EL0 do NOT come here — they take swift_sync_lower in
/// Kernel/Userspace.swift, which services SVCs and kills faulting runs.)
@_cdecl("swift_fatal_exception")
func swiftFatalException(_ kind: UInt64, _ esr: UInt64, _ elr: UInt64,
                         _ far: UInt64, _ spsr: UInt64,
                         _ regs: UnsafePointer<UInt64>) -> Never {
    Panic.fatal(kind: kind, esr: esr, elr: elr, far: far, spsr: spsr, regs: regs)
}
