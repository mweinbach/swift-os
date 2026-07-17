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
    var totalMemoryMB: Double { 512 }
    var usedMemoryMB: Double {
        16 + Double(KernelHeap.usedBytes) / (1024 * 1024)
    }

    // Processes / boot
    var loadAverage: (Double, Double, Double) {
        let active = Double(Tasks.list.filter { $0.cpuPercent > 2 }.count)
        let one = 0.05 + active * 0.18
        return (one, one * 0.8, one * 0.6)
    }
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
    }
}
