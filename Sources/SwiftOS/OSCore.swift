import Foundation
import CoreGraphics

// MARK: - Color

struct Color: Equatable {
    var r: Double, g: Double, b: Double, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    static func hex(_ value: UInt32, alpha: Double = 1) -> Color {
        Color(Double((value >> 16) & 0xFF) / 255,
              Double((value >> 8) & 0xFF) / 255,
              Double(value & 0xFF) / 255, alpha)
    }
    func withAlpha(_ alpha: Double) -> Color { Color(r, g, b, alpha) }

    static let clear = Color(0, 0, 0, 0)
    static let black = Color(0, 0, 0)
    static let white = Color(1, 1, 1)

    static let desktopTop         = Color.hex(0x2E3440)
    static let desktopBottom      = Color.hex(0x1B1E25)
    static let panel              = Color.hex(0x191C21)
    static let panelText          = Color.hex(0xD8DEE9)
    static let taskbar            = Color.hex(0x14161B)
    static let windowBackground   = Color.hex(0x23262D)
    static let windowBorder       = Color.hex(0x0E1013)
    static let titleBar           = Color.hex(0x2C3037)
    static let titleBarFocused    = Color.hex(0x3A3F47)
    static let titleText          = Color.hex(0xE5E9F0)
    static let titleTextDim       = Color.hex(0x9DA3AE)
    static let accent             = Color.hex(0x3584E4)
    static let selection          = Color.hex(0x2B4C6E)
    static let green              = Color.hex(0x33D17A)
    static let red                = Color.hex(0xE01B24)
    static let yellow             = Color.hex(0xE5A50A)
    static let orange             = Color.hex(0xFF7800)
    static let purple             = Color.hex(0x9141AC)
    static let cyan               = Color.hex(0x35C4B5)
    static let blue               = Color.hex(0x62A0EA)
    static let gray               = Color.hex(0x9A9996)
    static let darkGray           = Color.hex(0x5E5C64)
    static let lightGray          = Color.hex(0xC0BFBC)
    static let terminalBackground = Color.hex(0x0D0F13)
    static let terminalText       = Color.hex(0xD8DEE9)
}

// MARK: - Geometry helpers

extension CGPoint {
    func offsetBy(x: CGFloat = 0, y: CGFloat = 0) -> CGPoint {
        CGPoint(x: self.x + x, y: self.y + y)
    }
}

// MARK: - Surface (the immediate-mode 2D drawing API implemented by the Metal renderer)

/// All drawing happens in SCREEN coordinates, in POINTS, origin at the TOP-LEFT
/// of the screen, y growing downward. Apps receive their clipped content rect in
/// `OSApp.draw(_:in:)` and should store it to map mouse events (also screen coords).
protocol Surface: AnyObject {
    /// Size of the whole screen in points.
    var size: CGSize { get }
    func clear(_ color: Color)
    func fill(_ rect: CGRect, color: Color)
    func stroke(_ rect: CGRect, color: Color, width: CGFloat)
    func line(from p1: CGPoint, to p2: CGPoint, color: Color, width: CGFloat)
    func fillCircle(center: CGPoint, radius: CGFloat, color: Color)
    /// Draws monospace text. `point` is the TOP-LEFT corner of the text's bounding box.
    /// `scale` 1 is the base terminal size (~13pt), 2 is double size, etc.
    func text(_ string: String, at point: CGPoint, color: Color, scale: CGFloat)
    /// Pixel-exact advance width and line height for `string` at `scale`.
    /// MUST agree with `text(_:at:color:scale:)` or every layout in the system breaks.
    func textSize(_ string: String, scale: CGFloat) -> CGSize
    /// Clip stack: subsequent drawing is restricted to `rect` (intersected with the
    /// current clip) until the matching `popClip()`.
    func pushClip(_ rect: CGRect)
    func popClip()
}

extension Surface {
    func text(_ string: String, at point: CGPoint, color: Color) {
        text(string, at: point, color: color, scale: 1)
    }
    func textSize(_ string: String) -> CGSize {
        textSize(string, scale: 1)
    }
    func stroke(_ rect: CGRect, color: Color) {
        stroke(rect, color: color, width: 1)
    }
}

// MARK: - Events

struct KeyModifiers: OptionSet {
    let rawValue: UInt
    static let shift   = KeyModifiers(rawValue: 1 << 0)
    static let control = KeyModifiers(rawValue: 1 << 1)
    static let option  = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)
}

struct KeyEvent {
    let keyCode: UInt16
    /// Printable text for this key (may be "" or a private-use unicode for special keys).
    /// Use `keyCode` for navigation/editing keys: arrows are 123/124/125/126 (L/R/U/D),
    /// Return 36, Backspace 51, Escape 53, Tab 48, Space 49, PageUp 116, PageDown 121,
    /// Home 115, End 119, Forward-Delete 117.
    let characters: String
    let modifiers: KeyModifiers
    let isRepeat: Bool
}

enum OSEvent {
    case keyDown(KeyEvent)
    case keyUp(KeyEvent)
    case mouseDown(CGPoint)
    case rightMouseDown(CGPoint)
    case mouseUp(CGPoint)
    case mouseMoved(CGPoint)
    case mouseDragged(CGPoint)
    case scrollWheel(at: CGPoint, deltaX: CGFloat, deltaY: CGFloat)
}

// MARK: - OSApp (a windowed application)

protocol OSApp: AnyObject {
    var title: String { get }
    var preferredContentSize: CGSize { get }
    /// Draw the app. `rect` is your content region in SCREEN coordinates and is already
    /// clipped. Store it if you need to map mouse events (which are also screen coords).
    func draw(_ surface: Surface, in rect: CGRect)
    func handle(_ event: OSEvent)
    func tick(_ dt: TimeInterval)
}

extension OSApp {
    func handle(_ event: OSEvent) {}
    func tick(_ dt: TimeInterval) {}
}

// MARK: - OSWindow

final class OSWindow {
    let id = UUID()
    let app: OSApp
    var frame: CGRect
    var isMinimized = false
    var isMaximized = false
    var restoreFrame: CGRect = .zero
    var processPID: Int?

    init(app: OSApp, frame: CGRect) {
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
        window.processPID = Kernel.shared.registerProcess(name: app.title)
        windows.append(window)
        focus(window)
        return window
    }

    func close(_ window: OSWindow) {
        if let pid = window.processPID { Kernel.shared.unregisterProcess(pid: pid) }
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
    private var cascadeIndex = 0
    private var lastTitleClick: (window: ObjectIdentifier, time: TimeInterval)?

    func handle(_ event: OSEvent) {
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
                let now = Date().timeIntervalSince1970
                if let last = lastTitleClick, last.window == ObjectIdentifier(window), now - last.time < 0.35 {
                    toggleMaximize(window)
                    lastTitleClick = nil
                    return
                }
                lastTitleClick = (ObjectIdentifier(window), now)
                dragMode = .move
                dragWindow = window
                dragOffset = CGPoint(x: p.x - window.frame.minX, y: p.y - window.frame.minY)
            case .resize:
                dragMode = .resize
                dragWindow = window
                dragStartFrame = window.frame
                dragStartPoint = p
            case .content:
                window.app.handle(event)
            }
        case .rightMouseDown:
            if Desktop.shared.handle(event) { return }
            if let (window, zone) = hitTest(p(for: event)), zone == .content {
                focus(window)
                window.app.handle(event)
            }
        case .mouseDragged(let p):
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
            case .none:
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
        case .mouseMoved:
            _ = Desktop.shared.handle(event)
            focused?.app.handle(event)
        case .scrollWheel(let p, _, _):
            if let (window, _) = hitTest(p) {
                window.app.handle(event)
            } else {
                _ = Desktop.shared.handle(event)
            }
        case .keyDown, .keyUp:
            if let focused {
                focused.app.handle(event)
            } else {
                _ = Desktop.shared.handle(event)
            }
        }
    }

    private func p(for event: OSEvent) -> CGPoint {
        if case .rightMouseDown(let p) = event { return p }
        return .zero
    }

    // MARK: Tick

    func tick(_ dt: TimeInterval) {
        Kernel.shared.tick(dt)
        Desktop.shared.tick(dt)
        for window in windows where !window.isMinimized {
            window.app.tick(dt)
        }
    }
}

// MARK: - Kernel (process table, boot log, uptime, memory)

struct ProcessInfo {
    let pid: Int
    var name: String
    var cpuPercent: Double
    var memoryMB: Double
    var state: String // "R" running, "S" sleeping
    var baselineCPU: Double
}

final class Kernel {
    static let shared = Kernel()

    let username = "user"
    let hostname = "swiftos"
    let osName = "SwiftOS"
    let osVersion = "1.0"
    let kernelRelease = "6.9.4-swift"
    let machine = "arm64"
    let shellName = "swish 5.2"
    let wmName = "swiftcomp"
    let terminalName = "swift-term"
    let totalMemoryMB: Double = 8192
    let bootDate = Date()

    let bootLog: [String] = [
        "[    0.000000] Booting SwiftOS on physical CPU",
        "[    0.000000] SwiftOS version 1.0 (swiftc 6.2) #1 SMP arm64",
        "[    0.004121] CPU: Apple Silicon, 8 processors",
        "[    0.009810] Memory: 8192MB available",
        "[    0.012002] Initializing cgroup subsys cpuset",
        "[    0.014557] Initializing cgroup subsys cpuacct",
        "[    0.018844] VFS: Disk quotas dquot_6.6.0",
        "[    0.023190] swiftfs: mounted root filesystem read-write",
        "[    0.027731] pnp: PnP ACPI init",
        "[    0.031337] Metal: GPU pipeline initialized (AGX)",
        "[    0.036650] clocksource: Switched to clocksource swift-timer",
        "[    0.044201] swiftcomp: compositor online, 60Hz",
        "[    0.052881] input: swift-hid keyboard/mouse attached",
        "[    0.061004] NET: Registered protocol family 17",
        "[    0.068412] systemd[1]: Reached target Local File Systems",
        "[    0.071992] systemd[1]: Starting D-Bus System Message Bus...",
        "[    0.079305] systemd[1]: Starting Network Manager...",
        "[    0.084167] systemd[1]: Reached target Multi-User System",
        "[    0.089944] systemd[1]: Started Swift Display Manager",
        "[    0.093102] swift-term: pseudo-terminal driver ready",
    ]

    private(set) var processes: [ProcessInfo] = []
    private var nextPID = 120
    private var jitterAccumulator: TimeInterval = 0

    private init() {
        let seeds: [(String, Double, Double)] = [
            ("systemd", 0.2, 12), ("kthreadd", 0.0, 0), ("kworker/0:1", 0.3, 0),
            ("kworker/1:0", 0.2, 0), ("ksoftirqd/0", 0.0, 0), ("rcu_sched", 0.1, 0),
            ("dbus-daemon", 0.1, 6), ("NetworkManager", 0.3, 14), ("systemd-logind", 0.1, 8),
            ("cron", 0.0, 4), ("rsyslogd", 0.1, 9), ("swiftcomp", 1.4, 86),
        ]
        var pid = 1
        for (name, cpu, mem) in seeds {
            processes.append(ProcessInfo(pid: pid, name: name, cpuPercent: cpu,
                                         memoryMB: mem, state: "S", baselineCPU: cpu))
            pid += pid == 1 ? 1 : Int.random(in: 2...9)
        }
    }

    @discardableResult
    func registerProcess(name: String) -> Int {
        let pid = nextPID
        nextPID += 1
        let cpu = Double.random(in: 2...7)
        processes.append(ProcessInfo(pid: pid, name: name, cpuPercent: cpu,
                                     memoryMB: Double.random(in: 35...110), state: "R",
                                     baselineCPU: cpu))
        return pid
    }

    func unregisterProcess(pid: Int) {
        processes.removeAll { $0.pid == pid }
    }

    func tick(_ dt: TimeInterval) {
        jitterAccumulator += dt
        guard jitterAccumulator >= 0.4 else { return }
        jitterAccumulator = 0
        for i in processes.indices {
            let base = processes[i].baselineCPU
            let delta = Double.random(in: -1.2...1.6)
            processes[i].cpuPercent = max(0, min(base + delta, base > 1 ? 32 : 7))
            processes[i].memoryMB = max(0, processes[i].memoryMB + Double.random(in: -1.5...1.5))
            processes[i].state = processes[i].cpuPercent > 1.5 ? "R" : "S"
        }
    }

    var uptime: TimeInterval { Date().timeIntervalSince(bootDate) }

    var usedMemoryMB: Double {
        min(totalMemoryMB - 300, 1350 + processes.reduce(0) { $0 + $1.memoryMB })
    }

    var loadAverage: (Double, Double, Double) {
        let active = Double(processes.filter { $0.cpuPercent > 2 }.count)
        let one = 0.08 + active * 0.21
        return (one, one * 0.82, one * 0.63)
    }
}
