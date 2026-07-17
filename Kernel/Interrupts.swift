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
    fileprivate static func handleIrq(_ iar: UInt32) {
        if (iar & 0x3FF) == timerIntid {
            tickCount &+= 1
            armWriteCntpTval(ticksPerPeriod)    // next 10 ms tick
        }
        mmioWrite32(GIC.cEOIR, iar)
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

/// Synchronous exception at EL1h: dump ESR/ELR, then die.
@_cdecl("swift_sync_exception")
func swiftSyncException(_ esr: UInt64, _ elr: UInt64) -> Never {
    kprint("\nSYNC EXCEPTION  ESR=")
    kprintHex(esr)
    kprint("  ELR=")
    kprintHex(elr)
    kprint("\n")
    kpanic("unhandled synchronous exception")
}

@_cdecl("swift_fiq_exception")
func swiftFiqException() -> Never {
    kpanic("unexpected FIQ")
}

@_cdecl("swift_serror_exception")
func swiftSerrorException(_ esr: UInt64, _ elr: UInt64) -> Never {
    kprint("\nSERROR  ESR=")
    kprintHex(esr)
    kprint("  ELR=")
    kprintHex(elr)
    kprint("\n")
    kpanic("unhandled SError")
}

/// A vector row the kernel should never take (SP0 / lower EL).
@_cdecl("swift_unexpected_vector")
func swiftUnexpectedVector() -> Never {
    kpanic("unexpected exception vector")
}
