// Kernel-wide configuration switches.

enum Config {
    /// MMU + caches. Required for correctness: with the MMU off, the core
    /// faults on the unaligned 16-byte SIMD stores the Swift runtime emits.
    /// Under QEMU TCG, DMA is coherent with the caches, so the drivers are
    /// safe without explicit cache maintenance. (Real hardware would need
    /// cache clean/invalidate around DMA buffers — see MMU.swift.)
    static let enableMMU = true

    /// Framebuffer geometry requested from ramfb.
    static let screenWidth = 1280
    static let screenHeight = 800

    /// Machine profile (QEMU Pi 5 match: cortex-a76, 4 cores, 8 GiB).
    static let ramMB = 8192
    static let cpuCount = 4
    /// PSCI CPU_ON bring-up of secondary cores (parked secondaries for now;
    /// the scheduler and heap remain main-CPU only).
    static let smpEnabled = true

    /// Preemptive round-robin kernel threads (Kernel/Scheduler.swift).
    /// When false, Scheduler.initScheduler() is a no-op and the timer tick
    /// never context-switches: the compositor loop runs alone, exactly as
    /// before. Flip to true only together with calling
    /// Scheduler.initScheduler() from kmain.
    static let enableScheduler = true

    /// EL0 userspace: run the embedded demo blob unprivileged and service
    /// its SVC syscalls (Kernel/Userspace.swift). When false,
    /// UserProcess.runDemo() is a no-op returning "udemo: userspace
    /// disabled". The supporting machinery (lower-EL vector rows, the MMU
    /// L2 split) is inert while the gate is off: nothing ever drops to EL0,
    /// so those vectors never fire, and the L2 split is byte-for-byte the
    /// same translation as the old 1 GiB RAM block.
    static let enableUserland = true
}
