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

    /// Preemptive round-robin kernel threads (Kernel/Scheduler.swift).
    /// When false, Scheduler.initScheduler() is a no-op and the timer tick
    /// never context-switches: the compositor loop runs alone, exactly as
    /// before. Flip to true only together with calling
    /// Scheduler.initScheduler() from kmain.
    static let enableScheduler = true
}
