// Kernel entry and the compositor main loop.
//
// Boot order: UART (diagnostics) -> Clock -> Heap (everything dynamic depends
// on posix_memalign) -> services -> subsystems -> userland session.

@_cdecl("kmain")
public func kmain(dtb: UInt) -> Never {
    UART.initUART()
    // Machine discovery from the device tree (Kernel/DTB.swift). x0 is 0 on
    // QEMU's ELF bare-metal boot path, so discover() probes the RAM base.
    // Runs before the heap is up: allocation-free, kprint-family logging
    // only, compiled-in defaults on any failure.
    _ = Machine.discover(dtb: dtb)
    Clock.initClock()
    KernelHeap.initHeap()

    klog("SwiftOS kernel 1.0.0-aarch64 (Embedded Swift, bare metal)")
    klog("[boot] exception level EL\(armReadCurrentEL())")
    klog("[boot] timer frequency \(Clock.frequency) Hz")
    klog("[boot] heap \(KernelHeap.totalBytes / (1024 * 1024)) MB")

    _ = FontData.bitmap.count // warm the lazy font for the panic renderer

    if KernelHeap.selfTest() {
        klog("[boot] heap self-test ok")
    } else {
        kpanic("heap self-test failed")
    }

    Platform.services = KernelServices.shared
    _ = Tasks.register(name: "kernel", memoryMB: 16)

    if Config.enableMMU {
        if MMU.initMMU() {
            klog("[boot] mmu: identity map enabled")
        } else {
            klog("[boot] mmu: init failed, continuing with mmu off")
        }
    }

    Interrupts.initInterrupts()
    Scheduler.initScheduler()
    SMP.startSecondaries()
    let haveDisplay = Display.initDisplay()
    if !haveDisplay {
        klog("[boot] no ramfb device — continuing headless (serial only)")
    }
    _ = Input.initInput()
    _ = Net.initNet()

    let compositorID = Tasks.register(name: "swiftcomp", memoryMB: 32)
    let inputID = Tasks.register(name: "inputd", memoryMB: 4)

    // Display-manager session: the terminal ends up focused (opened last).
    WindowManager.shared.open(app: SystemMonitorApp(), at: Point(x: 800, y: 340))
    WindowManager.shared.open(app: TerminalApp(), at: Point(x: 150, y: 84))

    guard haveDisplay else {
        klog("[boot] kernel idle")
        while true { armWfi() }
    }

    let surface = SoftwareSurface(pixels: Display.backBuffer,
                                  width: Display.width,
                                  height: Display.height,
                                  strideBytes: Display.strideBytes)
    var lastTimeMs = Clock.uptimeMs

    // Frame-skip state: present only when something observable changed —
    // input arrived, the cursor moved, or new drawing happened outside the
    // loop (drawCalls is bumped by every SoftwareSurface primitive, so it
    // only changes when drawFrame/drawCursor ran). A staleness cap forces a
    // redraw at least every 500 ms because apps animate without any input
    // (terminal cursor blink, panel clock, monitor graph).
    var lastPresentedDraws = -1
    var lastCursorX = -1
    var lastCursorY = -1
    var lastPresentMs: UInt64 = 0
    let staleAfterMs: UInt64 = 500

    klog("[boot] login session started — compositor running")

    while true {
        Net.poll()
        // --- input -------------------------------------------------------
        let events = Input.pollEvents()
        if !events.isEmpty {
            Tasks.noteRun(id: inputID)
            for event in events {
                WindowManager.shared.handle(event)
            }
        }

        // --- tick ----------------------------------------------------------
        let nowMs = Clock.uptimeMs
        let dt = Double(nowMs - lastTimeMs) / 1000.0
        lastTimeMs = nowMs
        KernelServices.shared.tick(dt: dt)
        WindowManager.shared.tick(dt)

        // --- frame ---------------------------------------------------------
        let cursorMoved = Input.mouseX != lastCursorX || Input.mouseY != lastCursorY
        let stale = nowMs &- lastPresentMs >= staleAfterMs
        if !events.isEmpty || cursorMoved || stale
            || surface.drawCalls != lastPresentedDraws {
            WindowManager.shared.drawFrame(surface)
            drawCursor(surface)
            Display.present()
            lastPresentedDraws = surface.drawCalls
            lastCursorX = Input.mouseX
            lastCursorY = Input.mouseY
            lastPresentMs = nowMs
            Tasks.noteRun(id: compositorID)
        }

        // --- pace ----------------------------------------------------------
        Interrupts.waitForNextTick()
    }
}

/// Software mouse cursor: a small white arrow with a dark edge, drawn last
/// (on top of the panel/taskbar and all windows).
private func drawCursor(_ surface: Surface) {
    let x = Double(Input.mouseX)
    let y = Double(Input.mouseY)

    // Arrow outline (dark), then fill (white) — classic pointer silhouette.
    let outline: [(Double, Double)] = [
        (0, 0), (0, 15), (4, 11.5), (6.5, 17), (9, 15.5), (6.5, 10), (11, 10),
    ]
    // Edge pass
    for i in 0..<(outline.count - 1) {
        surface.line(from: Point(x: x + outline[i].0, y: y + outline[i].1),
                     to: Point(x: x + outline[i + 1].0, y: y + outline[i + 1].1),
                     color: .black, width: 3)
    }
    surface.line(from: Point(x: x + outline[outline.count - 1].0, y: y + outline[outline.count - 1].1),
                 to: Point(x: x, y: y),
                 color: .black, width: 3)
    // Fill pass (smaller, so a dark rim remains)
    for i in 0..<(outline.count - 1) {
        surface.line(from: Point(x: x + outline[i].0, y: y + outline[i].1),
                     to: Point(x: x + outline[i + 1].0, y: y + outline[i + 1].1),
                     color: .white, width: 1.4)
    }
    surface.line(from: Point(x: x + outline[outline.count - 1].0, y: y + outline[outline.count - 1].1),
                 to: Point(x: x, y: y),
                 color: .white, width: 1.4)
}
