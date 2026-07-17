// Kernel entry. Boot order matters: UART first (diagnostics), then the heap
// (everything dynamic depends on posix_memalign), then everything else.
// The compositor loop at the bottom is wired up as subsystems land.

@_cdecl("kmain")
public func kmain(dtb: UInt) -> Never {
    UART.initUART()
    Clock.initClock()
    KernelHeap.initHeap()

    klog("SwiftOS kernel 1.0.0-aarch64 (Embedded Swift, bare metal)")
    klog("[boot] exception level EL\(armReadCurrentEL())")
    klog("[boot] timer frequency \(Clock.frequency) Hz")
    klog("[boot] heap \(KernelHeap.totalBytes / (1024 * 1024)) MB")
    klog("[boot] dtb at \(dtb)")

    Platform.services = KernelServices.shared
    Tasks.register(name: "kernel", memoryMB: 16)

    // Subsystems are initialized here as they land:
    //   Interrupts.initInterrupts()
    //   Display.initDisplay()
    //   Input.initInput()

    klog("[boot] kernel up — waiting for subsystems")

    while true {
        armWfi()
    }
}
