// Kernel-wide configuration switches.

enum Config {
    /// MMU + caches. Stage-2 feature: the memory subsystem proves itself
    /// with the MMU off first, then this flips on.
    static let enableMMU = false

    /// Framebuffer geometry requested from ramfb.
    static let screenWidth = 1280
    static let screenHeight = 800
}
