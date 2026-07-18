// Kernel-side implementation of the OSServices seam. Real values from real
// kernel subsystems: Clock, KernelHeap, Tasks, BootLog.

final class KernelServices {
    static let shared = KernelServices()

    // Identity
    let username = "user"
    let hostname = "swiftos"
    let osName = "SwiftOS"
    let osVersion = "1.0"
    let kernelRelease = "1.0.0-aarch64"
    let machine = "aarch64"
    let shellName = "swish 5.2"
    let wmName = "swiftcomp"
    let terminalName = "swift-term"

    /// Fake-but-fixed wall clock anchor: ms since epoch at boot
    /// (2026-07-17 ~12:30 UTC) + real uptime.
    private let bootWallClockMs: UInt64 = 1_784_300_000_000

    // Time
    var uptime: TimeInterval { Clock.uptimeSeconds }
    var uptimeMs: UInt64 { Clock.uptimeMs }
    var wallClockMs: UInt64 { bootWallClockMs &+ Clock.uptimeMs }

    // Memory
    var totalMemoryMB: Double { Double(Config.ramMB) }
    var usedMemoryMB: Double {
        16 + Double(KernelHeap.usedBytes) / (1024 * 1024)
    }

    // MARK: - Per-core load (SMP)

    /// Smoothed per-core busy fractions (0...1), one entry per online core,
    /// refreshed every frame in `tick(dt:)` from Scheduler.perCoreUsage().
    /// Empty until the first usable snapshot delta (and stays empty when the
    /// scheduler reports no per-core data, e.g. Config.enableScheduler off).
    /// Read by System Monitor's per-core bars and the terminal's TOP mode.
    private(set) var perCoreLoad: [Double] = []

    /// Previous raw per-core tick snapshot; fractions come from the DELTA
    /// between snapshots, not the cumulative counters themselves.
    private var prevCoreUsage: [(busy: UInt64, total: UInt64)]?

    /// EMA-smoothed load average in core units (0...Config.cpuCount), with
    /// 1:5:15-style time constants scaled down for demo liveliness (~4 s /
    /// ~20 s / ~60 s instead of minutes). Updated every frame in tick.
    private var load1 = 0.0
    private var load5 = 0.0
    private var load15 = 0.0

    // Processes / boot
    var loadAverage: (Double, Double, Double) { (load1, load5, load15) }
    var bootLog: [String] { BootLog.lines }
    var processes: [ProcessInfo] {
        Tasks.list.map {
            ProcessInfo(pid: $0.id, name: $0.name, cpuPercent: $0.cpuPercent,
                        memoryMB: $0.memoryMB, state: $0.state, baselineCPU: 0)
        }
    }

    func registerProcess(name: String) -> Int {
        Tasks.register(name: name, memoryMB: 8)
    }

    func unregisterProcess(pid: Int) {
        Tasks.unregister(id: pid)
    }

    /// Called once per frame from the kernel main loop.
    func tick(dt: TimeInterval) {
        var total: UInt64 = 0
        for t in Tasks.list { total &+= t.cpuTicks }
        Tasks.foldCpuPercent(totalDelta: total)
        sampleCores(dt: dt)
    }

    /// Refresh perCoreLoad from Scheduler.perCoreUsage() and fold the result
    /// into the smoothed load average. Fractions are delta-busy/delta-total
    /// between frames, EMA-smoothed (dt-aware, ~0.35 s constant) because a
    /// single frame covers only 1-2 timer ticks and is otherwise pure noise.
    private func sampleCores(dt: TimeInterval) {
        // Label-based tuple reads: compiles against both the pinned
        // [(busy:total:)] API and the temporary integration shim's
        // label order while the scheduler agent's real API is in flight.
        let snap = Scheduler.perCoreUsage().map { (busy: $0.busy, total: $0.total) }
        if let prev = prevCoreUsage, prev.count == snap.count, !snap.isEmpty {
            let alpha = min(1, max(0.005, dt / (dt + 0.35)))
            var fractions: [Double] = []
            fractions.reserveCapacity(snap.count)
            var anyDelta = false
            for i in snap.indices {
                let dTotal = snap[i].total &- prev[i].total
                let dBusy = snap[i].busy &- prev[i].busy
                if dTotal > 0 { anyDelta = true }
                let inst = dTotal > 0 ? min(1, Double(dBusy) / Double(dTotal)) : 0
                let old = i < perCoreLoad.count ? perCoreLoad[i] : 0
                fractions.append(old + alpha * (inst - old))
            }
            // Publish only when the scheduler actually accounted ticks this
            // frame — all-zero deltas mean "no per-core data yet" (e.g. the
            // all-zero integration shim), and the fallback estimate below
            // stays in charge instead of pinning every core to 0%.
            if anyDelta { perCoreLoad = fractions }
        }
        prevCoreUsage = snap

        // Instantaneous load in core units: sum of busy fractions (a machine
        // with three pegged cores reads ~3.0). Fallback without per-core
        // data: derive from the process table's %CPU (100% = one core).
        var inst = perCoreLoad.reduce(0, +)
        if perCoreLoad.isEmpty {
            var processCPU = 0.0
            for t in Tasks.list { processCPU += t.cpuPercent }
            inst = min(Double(Config.cpuCount), processCPU / 100)
        }
        load1 = ema(load1, towards: inst, dt: dt, tau: 4)
        load5 = ema(load5, towards: inst, dt: dt, tau: 20)
        load15 = ema(load15, towards: inst, dt: dt, tau: 60)
    }

    /// dt-aware exponential moving average (no libm exp() in the kernel):
    /// alpha = dt / (dt + tau), exact for alpha <= 1 and stable at any dt.
    private func ema(_ value: Double, towards target: Double, dt: TimeInterval,
                     tau: TimeInterval) -> Double {
        let alpha = min(1, max(0, dt / (dt + tau)))
        return value + alpha * (target - value)
    }
}
