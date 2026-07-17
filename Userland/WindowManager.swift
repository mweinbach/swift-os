// Window manager: window chrome, focus, drag/resize, event routing.
// Ported from Host-macOS/Sources/SwiftOS/OSCore.swift — behavior identical;
// Apple frameworks stripped. Mechanical changes vs. the reference:
//   - OSApp is a BASE CLASS (Embedded Swift has no protocol existentials)
//   - Kernel.shared -> Platform.services (register/unregisterProcess)
//   - Date().timeIntervalSince1970 -> Platform.services.uptimeMs (ms;
//     the double-click threshold of 0.35s becomes 350ms)
//   - UUID window ids -> a simple Int counter
//   - WindowManager.tick no longer ticks the kernel (services tick themselves)
// SwiftOS additions vs. the reference: global shortcuts (Ctrl+Alt+T opens a
// terminal, Alt+F4 / Ctrl+Alt+W closes the focused window), key capture for
// the desktop's wallpaper context menu, and Metacity-style Alt+drag window
// management (Alt+drag moves from anywhere in a window, Alt+right-drag or
// Alt+drag in the bottom-right quarter resizes).

// MARK: - OSApp (a windowed application)

/// A windowed application. BASE CLASS, not a protocol — subclass and
/// `override` (including `override init()` if you define one).
open class OSApp {
    public init() {}
    open var title: String { "" }
    open var preferredContentSize: Size { .zero }
    /// Draw the app. `rect` is your content region in SCREEN coordinates and is already
    /// clipped. Store it if you need to map mouse events (which are also screen coords).
    open func draw(_ surface: Surface, in rect: Rect) {}
    open func handle(_ event: OSEvent) {}
    open func tick(_ dt: TimeInterval) {}
}

// MARK: - OSWindow

fileprivate var nextWindowID = 1

final class OSWindow {
    let id: Int
    let app: OSApp
    var frame: CGRect
    var isMinimized = false
    var isMaximized = false
    var restoreFrame: CGRect = .zero
    var processPID: Int?

    init(app: OSApp, frame: CGRect) {
        self.id = nextWindowID
        nextWindowID += 1
        self.app = app
        self.frame = frame
    }

    var contentRect: CGRect {
        CGRect(x: frame.minX,
               y: frame.minY + WindowManager.titleBarHeight,
               width: frame.width,
               height: frame.height - WindowManager.titleBarHeight)
    }
}

// MARK: - WindowManager (window chrome, focus, drag/resize, event routing)

final class WindowManager {
    static let shared = WindowManager()

    static let titleBarHeight: CGFloat = 30
    static let panelHeight: CGFloat = 32
    static let taskbarHeight: CGFloat = 48
    static let resizeCorner: CGFloat = 20

    private(set) var windows: [OSWindow] = [] // bottom -> top
    private(set) var focused: OSWindow?
    var screenSize: CGSize = CGSize(width: 1440, height: 900)

    var usableScreen: CGRect {
        CGRect(x: 0, y: WindowManager.panelHeight,
               width: screenSize.width,
               height: screenSize.height - WindowManager.panelHeight - WindowManager.taskbarHeight)
    }

    // MARK: Window lifecycle

    @discardableResult
    func open(app: OSApp, at point: CGPoint? = nil) -> OSWindow {
        let usable = usableScreen
        let content = app.preferredContentSize
        let w = min(content.width, usable.width)
        let h = min(content.height + WindowManager.titleBarHeight, usable.height)
        let origin: CGPoint
        if let point {
            origin = point
        } else {
            let offset = CGFloat(cascadeIndex % 6) * 28
            origin = CGPoint(x: usable.midX - w / 2 + offset - 56,
                             y: usable.midY - h / 2 + offset - 56)
            cascadeIndex += 1
        }
        var frame = CGRect(origin: origin, size: CGSize(width: w, height: h))
        frame.origin.x = min(max(frame.origin.x, usable.minX), max(usable.minX, usable.maxX - frame.width))
        frame.origin.y = min(max(frame.origin.y, usable.minY), max(usable.minY, usable.maxY - frame.height))
        let window = OSWindow(app: app, frame: frame)
        window.processPID = Platform.services.registerProcess(name: app.title)
        windows.append(window)
        focus(window)
        return window
    }

    func close(_ window: OSWindow) {
        if let pid = window.processPID { Platform.services.unregisterProcess(pid: pid) }
        windows.removeAll { $0 === window }
        if focused === window { focused = windows.last(where: { !$0.isMinimized }) }
        if dragWindow === window { dragMode = .none; dragWindow = nil }
    }

    func closeApp(_ app: OSApp) {
        if let w = windows.first(where: { $0.app === app }) { close(w) }
    }

    func window(for app: OSApp) -> OSWindow? {
        windows.first { $0.app === app }
    }

    func focus(_ window: OSWindow) {
        windows.removeAll { $0 === window }
        windows.append(window)
        window.isMinimized = false
        focused = window
    }

    func minimize(_ window: OSWindow) {
        window.isMinimized = true
        if focused === window { focused = windows.last(where: { !$0.isMinimized }) }
    }

    func toggleMaximize(_ window: OSWindow) {
        if window.isMaximized {
            window.frame = window.restoreFrame
            window.isMaximized = false
        } else {
            window.restoreFrame = window.frame
            window.frame = usableScreen
            window.isMaximized = true
        }
    }

    // MARK: Drawing

    func drawFrame(_ surface: Surface) {
        screenSize = surface.size
        Desktop.shared.draw(surface)
        guard Desktop.shared.bootFinished else { return }
        for window in windows where !window.isMinimized {
            drawWindow(window, surface)
        }
        Desktop.shared.drawOverlay(surface)
    }

    private func drawWindow(_ window: OSWindow, _ s: Surface) {
        let isFocused = window === focused
        let frame = window.frame
        s.fill(frame, color: .windowBackground)

        // Title bar
        let bar = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: WindowManager.titleBarHeight)
        s.fill(bar, color: isFocused ? .titleBarFocused : .titleBar)
        let title = window.app.title
        let ts = s.textSize(title)
        s.text(title,
               at: CGPoint(x: bar.midX - ts.width / 2, y: bar.minY + (bar.height - ts.height) / 2),
               color: isFocused ? .titleText : .titleTextDim)

        // Window buttons (right side, GNOME style): minimize, maximize, close
        let buttons = buttonRects(window)
        let active: Color = isFocused ? .black.withAlpha(0.55) : .clear
        s.fillCircle(center: CGPoint(x: buttons.min.midX, y: buttons.min.midY), radius: 6,
                     color: isFocused ? .yellow : .darkGray)
        s.fillCircle(center: CGPoint(x: buttons.max.midX, y: buttons.max.midY), radius: 6,
                     color: isFocused ? .green : .darkGray)
        s.fillCircle(center: CGPoint(x: buttons.close.midX, y: buttons.close.midY), radius: 6,
                     color: isFocused ? .red : .darkGray)
        if isFocused {
            let cy = buttons.min.midY
            s.line(from: CGPoint(x: buttons.min.midX - 3, y: cy), to: CGPoint(x: buttons.min.midX + 3, y: cy),
                   color: active, width: 1.4)
            s.stroke(CGRect(x: buttons.max.midX - 3, y: cy - 3, width: 6, height: 6), color: active, width: 1.2)
            s.line(from: CGPoint(x: buttons.close.midX - 3, y: cy - 3), to: CGPoint(x: buttons.close.midX + 3, y: cy + 3),
                   color: active, width: 1.4)
            s.line(from: CGPoint(x: buttons.close.midX - 3, y: cy + 3), to: CGPoint(x: buttons.close.midX + 3, y: cy - 3),
                   color: active, width: 1.4)
        }

        s.stroke(frame, color: isFocused ? .accent.withAlpha(0.5) : .windowBorder, width: 1)

        // Content
        let content = window.contentRect
        s.fill(content, color: .windowBackground)
        s.pushClip(content)
        window.app.draw(s, in: content)
        s.popClip()

        // Resize corner hint
        let c = WindowManager.resizeCorner
        s.line(from: CGPoint(x: frame.maxX - c + 5, y: frame.maxY - 1),
               to: CGPoint(x: frame.maxX - 1, y: frame.maxY - c + 5),
               color: .darkGray, width: 1.5)
        s.line(from: CGPoint(x: frame.maxX - c + 11, y: frame.maxY - 1),
               to: CGPoint(x: frame.maxX - 1, y: frame.maxY - c + 11),
               color: .darkGray, width: 1.5)
    }

    private func buttonRects(_ window: OSWindow) -> (min: CGRect, max: CGRect, close: CGRect) {
        let cy = window.frame.minY + WindowManager.titleBarHeight / 2
        let close = CGRect(x: window.frame.maxX - 28, y: cy - 9, width: 18, height: 18)
        let maxB = CGRect(x: window.frame.maxX - 50, y: cy - 9, width: 18, height: 18)
        let minB = CGRect(x: window.frame.maxX - 72, y: cy - 9, width: 18, height: 18)
        return (minB, maxB, close)
    }

    // MARK: Event routing

    enum WindowZone { case close, minimize, maximize, titleBar, resize, content }

    func hitTest(_ p: CGPoint) -> (OSWindow, WindowZone)? {
        for window in windows.reversed() where !window.isMinimized {
            guard window.frame.contains(p) else { continue }
            let buttons = buttonRects(window)
            if buttons.close.contains(p) { return (window, .close) }
            if buttons.min.contains(p) { return (window, .minimize) }
            if buttons.max.contains(p) { return (window, .maximize) }
            if p.y < window.frame.minY + WindowManager.titleBarHeight { return (window, .titleBar) }
            if p.x > window.frame.maxX - WindowManager.resizeCorner &&
               p.y > window.frame.maxY - WindowManager.resizeCorner { return (window, .resize) }
            return (window, .content)
        }
        return nil
    }

    private enum DragMode { case none, move, resize }
    private var dragMode: DragMode = .none
    private var dragWindow: OSWindow?
    private var dragOffset: CGPoint = .zero
    private var dragStartFrame: CGRect = .zero
    private var dragStartPoint: CGPoint = .zero
    /// Latest known keyboard modifier state. OSEvent mouse events carry no
    /// modifiers, so this is tracked from keyDown/keyUp — the input driver
    /// emits key events for the modifier keys themselves (see VirtioInput).
    private var currentModifiers: KeyModifiers = []
    private var cascadeIndex = 0
    private var lastTitleClick: (window: Int, time: UInt64)?

    func handle(_ event: OSEvent) {
        // Track modifier state from key events (mouse events carry none); the
        // input driver emits keyDown/keyUp for the modifier keys themselves,
        // with the post-change modifier set attached.
        if case .keyDown(let key) = event {
            currentModifiers = key.modifiers
        } else if case .keyUp(let key) = event {
            currentModifiers = key.modifiers
        }
        guard Desktop.shared.bootFinished else {
            _ = Desktop.shared.handle(event)
            return
        }
        switch event {
        case .mouseDown(let p):
            if Desktop.shared.handle(event) { return }
            guard let (window, zone) = hitTest(p) else { return }
            focus(window)
            switch zone {
            case .close: close(window)
            case .minimize: minimize(window)
            case .maximize: toggleMaximize(window)
            case .titleBar:
                let now = Platform.services.uptimeMs
                if let last = lastTitleClick, last.window == window.id, now - last.time < 350 {
                    toggleMaximize(window)
                    lastTitleClick = nil
                    return
                }
                lastTitleClick = (window.id, now)
                startMoveDrag(window, at: p)
            case .resize:
                startResizeDrag(window, at: p)
            case .content:
                if currentModifiers.contains(.option) {
                    // Metacity-style Alt+drag: move from anywhere in the
                    // content area; resize from the bottom-right quarter.
                    // (The title-bar buttons above win even with Alt held.)
                    if p.x >= window.frame.midX && p.y >= window.frame.midY {
                        startResizeDrag(window, at: p)
                    } else {
                        startMoveDrag(window, at: p)
                    }
                } else {
                    window.app.handle(event)
                }
            }
        case .rightMouseDown(let p):
            if Desktop.shared.handle(event) { return }
            // Metacity-style Alt+right-drag: resize from anywhere in the
            // window (click-to-focus still happens first).
            if currentModifiers.contains(.option) {
                guard let (window, _) = hitTest(p) else { return }
                focus(window)
                startResizeDrag(window, at: p)
                return
            }
            if let (window, zone) = hitTest(p), zone == .content {
                focus(window)
                window.app.handle(event)
            }
        case .mouseDragged(let p):
            if dragMode != .none {
                applyDrag(to: p)
            } else {
                focused?.app.handle(event)
            }
        case .mouseUp:
            if dragMode != .none {
                dragMode = .none
                dragWindow = nil
                return
            }
            if Desktop.shared.handle(event) { return }
            focused?.app.handle(event)
        case .mouseMoved(let p):
            // A drag whose button state got lost arrives as mouseMoved — keep
            // driving the drag, and don't leak hover events to apps mid-drag.
            if dragMode != .none {
                applyDrag(to: p)
                return
            }
            _ = Desktop.shared.handle(event)
            focused?.app.handle(event)
        case .scrollWheel(let p, _, _):
            if let (window, _) = hitTest(p) {
                window.app.handle(event)
            } else {
                _ = Desktop.shared.handle(event)
            }
        case .keyDown(let key):
            if handleGlobalShortcut(key) { return } // consumed: never reaches apps
            if Desktop.shared.contextMenuActive {
                _ = Desktop.shared.handle(event) // menu captures keys (Escape dismisses)
                return
            }
            if let focused {
                focused.app.handle(event)
            } else {
                _ = Desktop.shared.handle(event)
            }
        case .keyUp:
            if let focused {
                focused.app.handle(event)
            } else {
                _ = Desktop.shared.handle(event)
            }
        }
    }

    // MARK: Drag helpers (title-bar drags and Metacity-style Alt-drags)

    /// Begin a title-bar-style move drag (also used by Alt+drag anywhere in
    /// a window's content area).
    private func startMoveDrag(_ window: OSWindow, at p: Point) {
        dragMode = .move
        dragWindow = window
        dragOffset = CGPoint(x: p.x - window.frame.minX, y: p.y - window.frame.minY)
    }

    /// Begin a bottom-right resize drag (resize corner, Alt+right-drag, or
    /// Alt+drag in the window's bottom-right quarter).
    private func startResizeDrag(_ window: OSWindow, at p: Point) {
        dragMode = .resize
        dragWindow = window
        dragStartFrame = window.frame
        dragStartPoint = p
    }

    /// Apply the active drag (move/resize) to the current pointer position.
    private func applyDrag(to p: Point) {
        switch dragMode {
        case .move:
            if let window = dragWindow {
                var origin = CGPoint(x: p.x - dragOffset.x, y: p.y - dragOffset.y)
                origin.y = max(origin.y, WindowManager.panelHeight)
                window.frame.origin = origin
            }
        case .resize:
            if let window = dragWindow {
                let newW = max(260, dragStartFrame.width + (p.x - dragStartPoint.x))
                let newH = max(170 + WindowManager.titleBarHeight,
                               dragStartFrame.height + (p.y - dragStartPoint.y))
                window.frame.size = CGSize(width: newW, height: newH)
            }
        case .none: break
        }
    }

    // MARK: Global shortcuts

    /// System-wide chords, handled before the focused app sees the event:
    /// Ctrl+Alt+T opens a terminal; Alt+F4 — or Ctrl+Alt+W, since the virtio
    /// input driver does not map F-keys — closes the focused window.
    /// Returns true when the event was consumed.
    private func handleGlobalShortcut(_ key: KeyEvent) -> Bool {
        let ctrlAlt = key.modifiers.contains(.control) && key.modifiers.contains(.option)
        // With Control held the input driver turns letters into control codes
        // (ctrl+t = 0x14, ctrl+w = 0x17), so match keyCodes as well as "t"/"w".
        if ctrlAlt && (key.characters == "t" || key.characters == "\u{14}" || key.keyCode == 17) {
            if !key.isRepeat { // consume repeats too: one terminal per press
                Desktop.shared.dismissMenus()
                open(app: TerminalApp())
            }
            return true
        }
        let altF4 = key.modifiers.contains(.option) && key.keyCode == 118
        let ctrlAltW = ctrlAlt && (key.characters == "w" || key.characters == "\u{17}" || key.keyCode == 13)
        if altF4 || ctrlAltW {
            if !key.isRepeat { // consume repeats too: one close per press
                Desktop.shared.dismissMenus()
                if let focused { close(focused) }
            }
            return true
        }
        return false
    }

    // MARK: Tick

    func tick(_ dt: TimeInterval) {
        Desktop.shared.tick(dt)
        for window in windows where !window.isMinimized {
            window.app.tick(dt)
        }
    }
}
