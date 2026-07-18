// GICv2 + ARM generic timer: exception vectors, IRQ dispatch, 100 Hz tick.
// QEMU virt: GICD at 0x0800_0000, GICC at 0x0801_0000. The EL1 physical
// timer (CNTP_*) is PPI 30 (INTID 30); SPIs start at 32.

@_silgen_name("arm_install_vectors") private func armInstallVectors()
@_silgen_name("arm_write_cntp_tval") private func armWriteCntpTval(_ value: UInt32)
@_silgen_name("arm_write_cntp_ctl")  private func armWriteCntpCtl(_ value: UInt32)

enum Interrupts {
    /// Timer ticks since initInterrupts() (1 tick = 10 ms).
    static private(set) var tickCount: UInt64 = 0

    /// GICv2 register map.
    private enum GIC {
        static let distBase: UInt = 0x0800_0000
        static let cpuBase:  UInt = 0x0801_0000

        static let dCtlr       = distBase + 0x000   // GICD_CTLR
        static let dISENABLER  = distBase + 0x100   // +4 per 32 interrupt IDs
        static let dIPRIORITYR = distBase + 0x400   // +4 per 4 IDs (byte fields)
        static let dITARGETSR  = distBase + 0x800   // +4 per 4 IDs, SPIs only

        static let cCtlr = cpuBase + 0x000          // GICC_CTLR
        static let cPMR  = cpuBase + 0x004          // GICC_PMR
        static let cEOIR = cpuBase + 0x010          // GICC_EOIR
    }

    /// EL1 physical timer PPI on the virt GIC.
    private static let timerIntid: UInt32 = 30
    /// Tick rate.
    private static let ticksPerSecond: UInt64 = 100
    /// CNTP cycles per tick, derived from Clock.frequency.
    private static var ticksPerPeriod: UInt32 = 0

    /// Install the vector table, bring up the GIC, and start the 100 Hz
    /// timer tick. Call once from kmain, after the heap is up.
    static func initInterrupts() {
        tickCount = 0
        ticksPerPeriod = UInt32(Clock.frequency / ticksPerSecond)

        armInstallVectors()

        // Distributor: enable, then priority + route + enable for INTID 30.
        mmioWrite32(GIC.dCtlr, 1)
        setPriority(timerIntid, 0xA0)
        enableInterrupt(timerIntid)

        // CPU interface: pass all priorities, enable signaling.
        mmioWrite32(GIC.cPMR, 0xFF)
        mmioWrite32(GIC.cCtlr, 1)

        // Arm the first 10 ms tick: ENABLE with IMASK clear.
        armWriteCntpTval(ticksPerPeriod)
        armWriteCntpCtl(1)

        armDsbSy()
        armIsb()
        armIrqEnable()

        klog("[gic] timer irq \(timerIntid) at \(ticksPerSecond) Hz")
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
    /// The EOI comes BEFORE Scheduler.onTimerTick: the scheduler hook may
    /// context-switch, and while the timer PPI is still active (not EOI'd)
    /// the GIC will not re-signal it — deferring EOI until the preempted
    /// thread resumes would starve the tick, and the scheduler itself is
    /// driven by that tick. EOI first, then the (never-blocking) hook.
    fileprivate static func handleIrq(_ iar: UInt32) {
        let intid = iar & 0x3FF
        if intid == timerIntid {
            tickCount &+= 1
            armWriteCntpTval(ticksPerPeriod)    // next 10 ms tick
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
