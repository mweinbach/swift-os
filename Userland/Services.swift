// Platform services: the seam between userland (window manager, shell, apps)
// and the kernel underneath. The kernel provides `KernelServices`; the macOS
// harness can provide its own implementation. Userland code reaches it through
// `Platform.services` — it replaces the old fake `Kernel.shared`.

public struct ProcessInfo {
    public let pid: Int
    public var name: String
    public var cpuPercent: Double
    public var memoryMB: Double
    public var state: String // "R" running, "S" sleeping
    public var baselineCPU: Double

    public init(pid: Int, name: String, cpuPercent: Double, memoryMB: Double,
                state: String, baselineCPU: Double) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryMB = memoryMB
        self.state = state
        self.baselineCPU = baselineCPU
    }
}

public enum Platform {
    /// Installed by the kernel very early in boot, before any userland runs.
    /// Concrete type: Embedded Swift has no protocol existentials.
    static var services: KernelServices!
}

// NOTE: services are the concrete `KernelServices` class (see
// Kernel/KernelServices.swift) — Embedded Swift bans `any Protocol`
// existentials, so there is deliberately no OSServices protocol type.
// `throws` in userland must be TYPED throws, e.g. `throws(VFSError)`.
