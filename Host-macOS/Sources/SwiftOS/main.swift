import AppKit
import Metal
import MetalKit
import QuartzCore

// MARK: - Host view: translates AppKit events into SwiftOS OSEvents.

final class OSView: MTKView {
    override var acceptsFirstResponder: Bool { true }

    private func osPoint(for event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y) // flip to top-left origin
    }

    private func osKeyEvent(_ event: NSEvent) -> KeyEvent {
        var modifiers: KeyModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        return KeyEvent(keyCode: event.keyCode,
                        characters: event.characters ?? "",
                        modifiers: modifiers,
                        isRepeat: event.isARepeat)
    }

    override func keyDown(with event: NSEvent) { WindowManager.shared.handle(.keyDown(osKeyEvent(event))) }
    override func keyUp(with event: NSEvent) { WindowManager.shared.handle(.keyUp(osKeyEvent(event))) }
    override func mouseDown(with event: NSEvent) { WindowManager.shared.handle(.mouseDown(osPoint(for: event))) }
    override func rightMouseDown(with event: NSEvent) { WindowManager.shared.handle(.rightMouseDown(osPoint(for: event))) }
    override func mouseUp(with event: NSEvent) { WindowManager.shared.handle(.mouseUp(osPoint(for: event))) }
    override func mouseMoved(with event: NSEvent) { WindowManager.shared.handle(.mouseMoved(osPoint(for: event))) }
    override func mouseDragged(with event: NSEvent) { WindowManager.shared.handle(.mouseDragged(osPoint(for: event))) }
    override func rightMouseDragged(with event: NSEvent) { WindowManager.shared.handle(.mouseDragged(osPoint(for: event))) }
    override func scrollWheel(with event: NSEvent) {
        WindowManager.shared.handle(.scrollWheel(at: osPoint(for: event),
                                                 deltaX: event.scrollingDeltaX,
                                                 deltaY: event.scrollingDeltaY))
    }
}

// MARK: - App host

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var renderer: MetalRenderer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: rect,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "SwiftOS"
        window.minSize = NSSize(width: 1024, height: 640)
        window.center()
        window.acceptsMouseMovedEvents = true

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("SwiftOS requires a Metal-capable GPU.")
        }
        let view = OSView(frame: window.contentLayoutRect, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0.05, 0.06, 0.08, 1)
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.autoresizingMask = [.width, .height]

        let renderer = MetalRenderer(view: view)
        var lastTime = CACurrentMediaTime()
        renderer.onFrame = { surface in
            let now = CACurrentMediaTime()
            let dt = now - lastTime
            lastTime = now
            WindowManager.shared.tick(dt)
            WindowManager.shared.drawFrame(surface)
        }
        self.renderer = renderer

        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        if CommandLine.arguments.contains("--demo") {
            // Opens a few apps right after boot — used for screenshot verification.
            Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { _ in
                let wm = WindowManager.shared
                wm.open(app: TerminalApp(), at: CGPoint(x: 48, y: 96))
                wm.open(app: FileManagerApp(), at: CGPoint(x: 660, y: 72))
                wm.open(app: SystemMonitorApp(), at: CGPoint(x: 930, y: 420))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
