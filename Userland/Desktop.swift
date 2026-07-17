// The desktop environment: boot console, wallpaper, desktop icons, top panel
// (Activities menu, focused-app title, clock, status glyphs) and bottom taskbar
// (launchers + window list). Drawn entirely through the immediate-mode Surface API.
//
// Ported from Host-macOS/Sources/SwiftOS/Desktop.swift. Embedded-Swift changes:
//   - Foundation/CoreGraphics removed (geometry comes from Userland/Geometry.swift)
//   - Kernel.shared -> Platform.services (bootLog/osName/osVersion/kernelRelease/
//     hostname/username/uptime — same member names)
//   - DateFormatter clock ("EEE HH:mm") -> TimeFmt.clock(services.wallClockMs),
//     rebuilt at most once per minute and cached
//   - Date() double-click timing -> services.uptime
//   - UUID window ids -> ObjectIdentifier (Embedded Swift has no Foundation UUID);
//     this also keeps Desktop independent of OSWindow's concrete id type
//   - libm cos/sin (wifi glyph) -> precomputed unit-circle points
//   - String.range(of:)/contains(substring) (Foundation) -> afterFirst(_:in:)

final class Desktop {
    static let shared = Desktop()

    /// false while the boot sequence is on screen; WindowManager hides windows until true.
    var bootFinished = false

    // MARK: - Boot state

    private var bootElapsed: TimeInterval = 0
    private let bootLineInterval: TimeInterval = 0.085
    private let bootLoginDelay: TimeInterval = 0.35
    private let bootDuration: TimeInterval = 3.0

    // MARK: - Launcher model

    private enum IconID { case home, terminal, files, editor, monitor }

    private struct LauncherItem {
        let id: IconID
        let label: String
    }

    private static let items: [LauncherItem] = [
        LauncherItem(id: .home, label: "Home"),
        LauncherItem(id: .terminal, label: "Terminal"),
        LauncherItem(id: .files, label: "Files"),
        LauncherItem(id: .editor, label: "Text Editor"),
        LauncherItem(id: .monitor, label: "System Monitor"),
    ]

    // MARK: - Interaction state

    /// A clickable piece of desktop chrome.
    private enum Target: Equatable {
        case activities
        case chrome // dead panel/taskbar area: consumed, no action
        case launcher(Int)
        case windowButton(ObjectIdentifier)
        case menuItem(Int)
        case icon(Int)
    }

    private var selectedIcon: IconID?
    private var lastIconClick: (id: IconID, time: TimeInterval)?
    private var menuOpen = false
    private var hover: Target?
    private var pressTarget: Target?

    // MARK: - Clock

    private var clockString = ""
    private var clockMinute: Int = -1

    // MARK: - Cached layout (measured with the Surface in drawOverlay, reused by hit-testing)

    private var cachedActivitiesRect: CGRect = .zero
    private var cachedWindowButtons: [(id: ObjectIdentifier, rect: CGRect)] = []

    // MARK: - Icon layout constants (8px padding rhythm)

    private let iconSlotX: CGFloat = 12
    private let iconSlotWidth: CGFloat = 76
    private let iconPitch: CGFloat = 84
    private let iconTopInset: CGFloat = 16

    private init() {}

    // MARK: - Layout helpers

    private func iconSlot(_ index: Int, size: CGSize) -> CGRect {
        CGRect(x: iconSlotX,
               y: WindowManager.panelHeight + iconTopInset + CGFloat(index) * iconPitch,
               width: iconSlotWidth, height: iconPitch - 6)
    }

    private func launcherRect(_ index: Int, size: CGSize) -> CGRect {
        CGRect(x: 8 + CGFloat(index) * 44,
               y: size.height - WindowManager.taskbarHeight + 4,
               width: 40, height: 40)
    }

    private func menuRect(size: CGSize) -> CGRect {
        CGRect(x: 4, y: WindowManager.panelHeight + 2,
               width: 208, height: 8 + CGFloat(Desktop.items.count) * 30 + 8)
    }

    private func menuItemRect(_ index: Int, size: CGSize) -> CGRect {
        let menu = menuRect(size: size)
        return CGRect(x: menu.minX + 4, y: menu.minY + 8 + CGFloat(index) * 30,
                      width: menu.width - 8, height: 30)
    }

    // MARK: - Drawing entry points

    /// Full-screen draw: wallpaper + desktop icons, or the boot console while !bootFinished.
    func draw(_ surface: Surface) {
        if !bootFinished {
            drawBoot(surface)
            return
        }
        let size = surface.size
        drawWallpaper(surface, size: size)
        drawIcons(surface, size: size)
    }

    /// Drawn ABOVE all windows: top panel + bottom taskbar (+ open Activities menu).
    func drawOverlay(_ surface: Surface) {
        guard bootFinished else { return }
        let size = surface.size
        updateClock()
        drawPanel(surface, size: size)
        drawTaskbar(surface, size: size)
        if menuOpen { drawMenu(surface, size: size) }
    }

    // MARK: - Boot sequence

    private func drawBoot(_ surface: Surface) {
        surface.clear(.black)
        let lineHeight = surface.textSize("M").height + 2
        let log = Platform.services.bootLog
        let visible = min(log.count, Int(bootElapsed / bootLineInterval))
        let okTag = "[  OK  ]"
        let messageX: CGFloat = 8 + surface.textSize(okTag + " ").width
        var y: CGFloat = 8
        for i in 0..<visible {
            let line = log[i]
            if afterFirst("systemd", in: line) != nil {
                surface.text(okTag, at: CGPoint(x: 8, y: y), color: .green)
                surface.text(bootMessage(from: line), at: CGPoint(x: messageX, y: y),
                             color: .terminalText)
            } else {
                surface.text(line, at: CGPoint(x: 8, y: y), color: .terminalText)
            }
            y += lineHeight
        }
        let loginTime = Double(log.count) * bootLineInterval + bootLoginDelay
        if bootElapsed >= loginTime {
            let k = Platform.services
            let dim = Color.terminalText.withAlpha(0.55)
            y += lineHeight / 2
            surface.text("\(k.osName) \(k.osVersion) \(k.hostname) tty1",
                         at: CGPoint(x: 8, y: y), color: dim)
            y += lineHeight
            surface.text("\(k.hostname) login: \(k.username) (automatic login)",
                         at: CGPoint(x: 8, y: y), color: dim)
        }
    }

    /// Turns a kernel-style "[  0.068412] systemd[1]: Starting X..." line into the
    /// bare service message that follows the "[  OK  ]" tag.
    private func bootMessage(from line: String) -> String {
        if let upper = afterFirst("systemd[1]: ", in: line) {
            return String(line[upper...])
        }
        if let close = line.firstIndex(of: "]") {
            let rest = line[line.index(after: close)...]
            return rest.first == " " ? String(rest.dropFirst()) : String(rest)
        }
        return line
    }

    /// Index just past the first occurrence of `needle` in `s`, or nil.
    /// Stdlib-only substring search (String.range(of:) is Foundation).
    private func afterFirst(_ needle: String, in s: String) -> String.Index? {
        if needle.isEmpty { return s.startIndex }
        var i = s.startIndex
        while i != s.endIndex {
            var a = i
            var b = needle.startIndex
            while b != needle.endIndex && a != s.endIndex && s[a] == needle[b] {
                a = s.index(after: a)
                b = s.index(after: b)
            }
            if b == needle.endIndex { return a }
            if a == s.endIndex { return nil }
            i = s.index(after: i)
        }
        return nil
    }

    // MARK: - Wallpaper

    private func drawWallpaper(_ surface: Surface, size: CGSize) {
        // Vertical gradient via horizontal strips.
        let strips = 64
        let stripHeight = size.height / CGFloat(strips)
        for i in 0..<strips {
            let t = Double(i) / Double(strips - 1)
            surface.fill(CGRect(x: 0, y: CGFloat(i) * stripHeight,
                                width: size.width, height: stripHeight + 1),
                         color: mixed(.desktopTop, .desktopBottom, t))
        }
        drawWallpaperGlyph(surface, size: size)

        let k = Platform.services
        let version = "\(k.osName) \(k.osVersion) (kernel \(k.kernelRelease))"
        let vs = surface.textSize(version)
        surface.text(version,
                     at: CGPoint(x: 12, y: size.height - WindowManager.taskbarHeight - vs.height - 10),
                     color: .panelText.withAlpha(0.45))
    }

    /// A large, very subtle ">_" terminal mark, centered-right.
    private func drawWallpaperGlyph(_ surface: Surface, size: CGSize) {
        let g = min(size.width, size.height) * 0.42
        guard g > 40 else { return }
        let cx = size.width * 0.70
        let cy = size.height * 0.44
        let color = Color.panelText.withAlpha(0.05)
        let lw = max(2, g * 0.055)
        let x0 = cx - g * 0.40
        let x1 = cx - g * 0.12
        let yTop = cy - g * 0.28
        let yBottom = cy + g * 0.28
        surface.line(from: CGPoint(x: x0, y: yTop), to: CGPoint(x: x1, y: cy),
                     color: color, width: lw)
        surface.line(from: CGPoint(x: x1, y: cy), to: CGPoint(x: x0, y: yBottom),
                     color: color, width: lw)
        surface.fill(CGRect(x: cx + g * 0.02, y: yBottom - lw / 2, width: g * 0.34, height: lw),
                     color: color)
    }

    private func mixed(_ a: Color, _ b: Color, _ t: Double) -> Color {
        Color(a.r + (b.r - a.r) * t,
              a.g + (b.g - a.g) * t,
              a.b + (b.b - a.b) * t,
              a.a + (b.a - a.a) * t)
    }

    // MARK: - Desktop icons

    private func drawIcons(_ surface: Surface, size: CGSize) {
        for (i, item) in Desktop.items.enumerated() {
            let slot = iconSlot(i, size: size)
            let iconRect = CGRect(x: slot.midX - 22, y: slot.minY + 2, width: 44, height: 44)
            let isSelected = selectedIcon == item.id
            let isHovered = hover == .icon(i)

            if isSelected {
                let highlight = iconRect.insetBy(dx: -6, dy: -6)
                surface.fill(highlight, color: .accent.withAlpha(0.30))
                surface.stroke(highlight, color: .accent.withAlpha(0.8), width: 1)
            } else if isHovered {
                surface.fill(iconRect.insetBy(dx: -6, dy: -6), color: .white.withAlpha(0.08))
            }

            drawGlyph(item.id, in: iconRect, surface: surface)

            // Label with a soft dark backing rect for readability.
            let ls = surface.textSize(item.label)
            let lx = max(4, slot.midX - ls.width / 2)
            let ly = iconRect.maxY + 5
            surface.fill(CGRect(x: lx - 4, y: ly - 2, width: ls.width + 8, height: ls.height + 4),
                         color: .black.withAlpha(0.4))
            surface.text(item.label, at: CGPoint(x: lx, y: ly),
                         color: isSelected ? .white : .panelText)
        }
    }

    /// Geometric app glyphs, drawn to fit any square-ish rect.
    private func drawGlyph(_ id: IconID, in r: CGRect, surface s: Surface) {
        let lw = max(1.2, r.width / 22)
        switch id {
        case .home:
            // House: filled body, peaked roof, accent door.
            let body = CGRect(x: r.minX + r.width * 0.18, y: r.minY + r.height * 0.44,
                              width: r.width * 0.64, height: r.height * 0.48)
            s.fill(body, color: .lightGray.withAlpha(0.9))
            let apex = CGPoint(x: r.midX, y: r.minY + r.height * 0.10)
            s.line(from: CGPoint(x: r.minX + r.width * 0.08, y: r.minY + r.height * 0.46),
                   to: apex, color: .lightGray, width: lw * 1.6)
            s.line(from: apex,
                   to: CGPoint(x: r.minX + r.width * 0.92, y: r.minY + r.height * 0.46),
                   color: .lightGray, width: lw * 1.6)
            s.fill(CGRect(x: r.midX - r.width * 0.07, y: r.minY + r.height * 0.62,
                          width: r.width * 0.14, height: r.height * 0.30),
                   color: .accent)
        case .terminal:
            // Dark screen with a green ">_" prompt.
            let scr = r.insetBy(dx: r.width * 0.04, dy: r.height * 0.08)
            s.fill(scr, color: .terminalBackground)
            s.stroke(scr, color: .darkGray, width: 1)
            let cx0 = scr.minX + scr.width * 0.14
            let cy0 = scr.minY + scr.height * 0.24
            let cw = scr.width * 0.22
            let ch = scr.height * 0.20
            s.line(from: CGPoint(x: cx0, y: cy0), to: CGPoint(x: cx0 + cw, y: cy0 + ch),
                   color: .green, width: lw)
            s.line(from: CGPoint(x: cx0 + cw, y: cy0 + ch), to: CGPoint(x: cx0, y: cy0 + 2 * ch),
                   color: .green, width: lw)
            s.fill(CGRect(x: cx0 + cw + scr.width * 0.08, y: cy0 + 2 * ch - scr.height * 0.06,
                          width: scr.width * 0.26, height: max(1.5, scr.height * 0.07)),
                   color: .green)
        case .files:
            // Blue folder with a tab.
            let bodyY = r.minY + r.height * 0.28
            let tabTop = r.minY + r.height * 0.16
            s.fill(CGRect(x: r.minX + r.width * 0.06, y: tabTop,
                          width: r.width * 0.40, height: bodyY - tabTop + 2),
                   color: .blue.withAlpha(0.85))
            let body = CGRect(x: r.minX + r.width * 0.04, y: bodyY,
                              width: r.width * 0.92, height: r.height * 0.60)
            s.fill(body, color: .blue.withAlpha(0.85))
            s.stroke(body, color: .black.withAlpha(0.35), width: 1)
        case .editor:
            // Diagonal pencil: graphite tip, yellow body, red eraser.
            let pw = max(2, r.width * 0.13)
            let tip = CGPoint(x: r.minX + r.width * 0.16, y: r.minY + r.height * 0.84)
            let wood = CGPoint(x: r.minX + r.width * 0.30, y: r.minY + r.height * 0.70)
            let end = CGPoint(x: r.minX + r.width * 0.70, y: r.minY + r.height * 0.30)
            let eraser = CGPoint(x: r.minX + r.width * 0.84, y: r.minY + r.height * 0.16)
            s.line(from: tip, to: wood, color: .lightGray, width: pw)
            s.line(from: wood, to: end, color: .yellow, width: pw)
            s.line(from: end, to: eraser, color: .red.withAlpha(0.85), width: pw)
            s.fillCircle(center: tip, radius: pw * 0.28, color: .darkGray)
        case .monitor:
            // Monitor with an activity graph and a stand.
            let scr = CGRect(x: r.minX + r.width * 0.06, y: r.minY + r.height * 0.08,
                             width: r.width * 0.88, height: r.height * 0.62)
            s.fill(scr, color: .terminalBackground)
            s.stroke(scr, color: .gray, width: 1)
            let points: [(CGFloat, CGFloat)] = [(0.12, 0.72), (0.30, 0.50), (0.45, 0.62),
                                                (0.60, 0.34), (0.78, 0.44), (0.88, 0.30)]
            var previous: CGPoint?
            for (px, py) in points {
                let p = CGPoint(x: scr.minX + scr.width * px, y: scr.minY + scr.height * py)
                if let previous {
                    s.line(from: previous, to: p, color: .green, width: lw)
                }
                previous = p
            }
            s.line(from: CGPoint(x: r.midX, y: scr.maxY),
                   to: CGPoint(x: r.midX, y: r.minY + r.height * 0.84),
                   color: .gray, width: lw)
            s.line(from: CGPoint(x: r.midX - r.width * 0.18, y: r.minY + r.height * 0.88),
                   to: CGPoint(x: r.midX + r.width * 0.18, y: r.minY + r.height * 0.88),
                   color: .gray, width: lw)
        }
    }

    // MARK: - Top panel

    private func drawPanel(_ surface: Surface, size: CGSize) {
        let h = WindowManager.panelHeight
        surface.fill(CGRect(x: 0, y: 0, width: size.width, height: h), color: .panel)
        surface.fill(CGRect(x: 0, y: h - 1, width: size.width, height: 1), color: .windowBorder)

        // Activities button.
        let label = "Activities"
        let ls = surface.textSize(label)
        let actRect = CGRect(x: 0, y: 0, width: ls.width + 28, height: h)
        cachedActivitiesRect = actRect
        if menuOpen {
            surface.fill(actRect, color: .selection)
        } else if hover == .activities {
            surface.fill(actRect, color: .white.withAlpha(0.08))
        }
        if pressTarget == .activities {
            surface.fill(actRect, color: .black.withAlpha(0.25))
        }
        surface.text(label, at: CGPoint(x: actRect.minX + 14, y: (h - ls.height) / 2),
                     color: .panelText)

        // Right cluster: [wifi] [battery] [clock].
        let clockSize = surface.textSize(clockString)
        let clockX = size.width - 12 - clockSize.width
        surface.text(clockString, at: CGPoint(x: clockX, y: (h - clockSize.height) / 2),
                     color: .panelText)
        let batteryRect = CGRect(x: clockX - 14 - 22, y: (h - 11) / 2, width: 22, height: 11)
        drawBattery(surface, rect: batteryRect)
        let wifiCenter = CGPoint(x: batteryRect.minX - 18, y: h / 2 + 5)
        drawWifi(surface, center: wifiCenter)
        let clusterMinX = wifiCenter.x - 14

        // Focused window's app title (dim), only where it cannot collide with the cluster.
        if let focused = WindowManager.shared.focused {
            var title = focused.app.title
            if title.count > 30 { title = String(title.prefix(27)) + "..." }
            let ts = surface.textSize(title)
            let tx = actRect.maxX + 16
            if tx + ts.width < clusterMinX - 8 {
                surface.text(title, at: CGPoint(x: tx, y: (h - ts.height) / 2),
                             color: .titleTextDim)
            }
        }
    }

    private func drawWifi(_ surface: Surface, center: CGPoint) {
        surface.fillCircle(center: center, radius: 1.5, color: .panelText)
        // Unit-circle (cos, sin) for 200°/235°/270°/305°/340°, precomputed —
        // libm trig is unavailable on the freestanding target.
        let steps: [(Double, Double)] = [
            (-0.9397, -0.3420), (-0.5736, -0.8192), (0.0, -1.0),
            (0.5736, -0.8192), (0.9397, -0.3420),
        ]
        let radii: [CGFloat] = [4.5, 7.5, 10.5]
        for radius in radii {
            var previous: CGPoint?
            for (c, s) in steps {
                let point = CGPoint(x: center.x + CGFloat(c) * radius,
                                    y: center.y + CGFloat(s) * radius)
                if let previous {
                    surface.line(from: previous, to: point, color: .panelText, width: 1.2)
                }
                previous = point
            }
        }
    }

    private func drawBattery(_ surface: Surface, rect: CGRect) {
        // Slow drain over a 2-hour cycle, purely cosmetic.
        let level = 0.9 * (1 - Platform.services.uptime.truncatingRemainder(dividingBy: 7200) / 7200) + 0.1
        surface.stroke(rect, color: .panelText, width: 1)
        surface.fill(CGRect(x: rect.maxX + 1, y: rect.midY - 2, width: 2, height: 4),
                     color: .panelText)
        let inner = rect.insetBy(dx: 2, dy: 2)
        let fillWidth = max(0, inner.width * CGFloat(level))
        if fillWidth > 0.5 {
            surface.fill(CGRect(x: inner.minX, y: inner.minY, width: fillWidth, height: inner.height),
                         color: level > 0.25 ? .green : .red)
        }
    }

    // MARK: - Activities menu

    private func drawMenu(_ surface: Surface, size: CGSize) {
        let rect = menuRect(size: size)
        surface.fill(rect, color: .windowBackground)
        surface.stroke(rect, color: .windowBorder, width: 1)
        for (i, item) in Desktop.items.enumerated() {
            let itemRect = menuItemRect(i, size: size)
            if hover == .menuItem(i) || pressTarget == .menuItem(i) {
                surface.fill(itemRect, color: .selection)
            }
            let glyphRect = CGRect(x: itemRect.minX + 6, y: itemRect.midY - 9, width: 18, height: 18)
            drawGlyph(item.id, in: glyphRect, surface: surface)
            let ls = surface.textSize(item.label)
            surface.text(item.label,
                         at: CGPoint(x: itemRect.minX + 32, y: itemRect.midY - ls.height / 2),
                         color: .panelText)
        }
    }

    // MARK: - Bottom taskbar

    private func drawTaskbar(_ surface: Surface, size: CGSize) {
        let h = WindowManager.taskbarHeight
        let barY = size.height - h
        surface.fill(CGRect(x: 0, y: barY, width: size.width, height: h), color: .taskbar)
        surface.fill(CGRect(x: 0, y: barY, width: size.width, height: 1), color: .windowBorder)

        // Launchers.
        for (i, item) in Desktop.items.enumerated() {
            let rect = launcherRect(i, size: size)
            if pressTarget == .launcher(i) {
                surface.fill(rect, color: .accent.withAlpha(0.35))
            } else if hover == .launcher(i) {
                surface.fill(rect, color: .white.withAlpha(0.10))
            }
            drawGlyph(item.id, in: rect.insetBy(dx: 8, dy: 8), surface: surface)
        }

        // Separator.
        let sepX = 8 + CGFloat(Desktop.items.count) * 44 + 4
        surface.fill(CGRect(x: sepX, y: barY + 10, width: 1, height: h - 20),
                     color: .darkGray.withAlpha(0.6))

        // Window buttons.
        cachedWindowButtons.removeAll(keepingCapacity: true)
        var x = sepX + 9
        let wm = WindowManager.shared
        for window in wm.windows {
            let title = truncatedTitle(window.app.title)
            let ts = surface.textSize(title)
            let width = ts.width + 24
            if x + width > size.width - 8 { break }
            let rect = CGRect(x: x, y: barY + 6, width: width, height: h - 12)
            let id = ObjectIdentifier(window)
            cachedWindowButtons.append((id, rect))

            if window.isMinimized {
                surface.fill(rect, color: .black.withAlpha(0.25))
            } else if wm.focused === window {
                surface.fill(rect, color: .accent.withAlpha(0.35))
                surface.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2),
                             color: .accent)
            } else if hover == .windowButton(id) {
                surface.fill(rect, color: .white.withAlpha(0.08))
            } else {
                surface.fill(rect, color: .white.withAlpha(0.04))
            }
            if pressTarget == .windowButton(id) {
                surface.fill(rect, color: .black.withAlpha(0.25))
            }
            surface.text(title, at: CGPoint(x: rect.minX + 12, y: rect.midY - ts.height / 2),
                         color: window.isMinimized ? .titleTextDim : .panelText)
            x += width + 6
        }
    }

    private func truncatedTitle(_ title: String) -> String {
        if title.count <= 14 { return title }
        return String(title.prefix(11)) + "..."
    }

    // MARK: - Events

    /// Returns true when the event was consumed (panel/taskbar/icon/menu hit).
    @discardableResult
    func handle(_ event: OSEvent) -> Bool {
        if !bootFinished {
            switch event {
            case .keyDown, .mouseDown, .rightMouseDown:
                bootFinished = true // any key/click skips the boot sequence
            default:
                break
            }
            return true
        }

        let size = WindowManager.shared.screenSize
        switch event {
        case .mouseDown(let p):
            if menuOpen {
                let t = target(at: p, size: size)
                var keepMenu = false
                if let t {
                    if case .menuItem = t { keepMenu = true }
                    if case .activities = t { keepMenu = true }
                }
                if keepMenu {
                    pressTarget = t
                } else {
                    menuOpen = false // click anywhere else dismisses (and is swallowed)
                    pressTarget = .chrome
                }
                return true
            }
            if let t = target(at: p, size: size) {
                pressTarget = t
                return true
            }
            if WindowManager.shared.hitTest(p) == nil {
                selectedIcon = nil // empty wallpaper clears the icon selection
            }
            return false
        case .mouseUp(let p):
            guard let pressed = pressTarget else {
                if menuOpen { return true }
                return target(at: p, size: size) != nil
            }
            pressTarget = nil
            guard pressed != .chrome else { return true }
            guard target(at: p, size: size) == pressed else { return true } // released off-target: cancel
            activate(pressed)
            return true
        case .mouseMoved(let p):
            hover = target(at: p, size: size)
            return false // plain hovers fall through to windows
        case .keyDown(let key):
            if menuOpen {
                if key.keyCode == 53 { menuOpen = false } // Escape
                return true
            }
            return false
        case .rightMouseDown:
            if menuOpen {
                menuOpen = false
                return true
            }
            return false
        default:
            return false
        }
    }

    /// Hit-tests desktop chrome. Returns nil for window-covered or empty-wallpaper points.
    private func target(at p: CGPoint, size: CGSize) -> Target? {
        if menuOpen {
            for i in Desktop.items.indices where menuItemRect(i, size: size).contains(p) {
                return .menuItem(i)
            }
        }
        if p.y < WindowManager.panelHeight {
            return cachedActivitiesRect.contains(p) ? .activities : .chrome
        }
        if p.y >= size.height - WindowManager.taskbarHeight {
            for i in Desktop.items.indices where launcherRect(i, size: size).contains(p) {
                return .launcher(i)
            }
            for button in cachedWindowButtons where button.rect.contains(p) {
                return .windowButton(button.id)
            }
            return .chrome
        }
        if WindowManager.shared.hitTest(p) != nil { return nil } // windows cover the desktop
        for i in Desktop.items.indices where iconSlot(i, size: size).contains(p) {
            return .icon(i)
        }
        return nil
    }

    private func activate(_ target: Target) {
        switch target {
        case .activities:
            menuOpen.toggle()
        case .launcher(let i):
            guard Desktop.items.indices.contains(i) else { return }
            launch(Desktop.items[i].id)
        case .menuItem(let i):
            guard Desktop.items.indices.contains(i) else { return }
            menuOpen = false
            launch(Desktop.items[i].id)
        case .windowButton(let id):
            let wm = WindowManager.shared
            guard let window = wm.windows.first(where: { ObjectIdentifier($0) == id }) else { return }
            if window.isMinimized {
                wm.focus(window)
            } else if wm.focused === window {
                wm.minimize(window)
            } else {
                wm.focus(window)
            }
        case .icon(let i):
            guard Desktop.items.indices.contains(i) else { return }
            let item = Desktop.items[i]
            let now = Platform.services.uptime
            if let last = lastIconClick, last.id == item.id, now - last.time <= 0.4 {
                lastIconClick = nil
                selectedIcon = item.id
                launch(item.id) // double-click
            } else {
                selectedIcon = item.id // single click selects
                lastIconClick = (item.id, now)
            }
        case .chrome:
            break
        }
    }

    private func launch(_ id: IconID) {
        switch id {
        case .home:
            WindowManager.shared.open(app: FileManagerApp(path: "/home/user"))
        case .terminal:
            WindowManager.shared.open(app: TerminalApp())
        case .files:
            WindowManager.shared.open(app: FileManagerApp())
        case .editor:
            WindowManager.shared.open(app: TextEditorApp())
        case .monitor:
            WindowManager.shared.open(app: SystemMonitorApp())
        }
    }

    // MARK: - Tick

    func tick(_ dt: TimeInterval) {
        if !bootFinished {
            bootElapsed += dt
            if bootElapsed >= bootDuration { bootFinished = true }
        }
        updateClock()
    }

    /// Rebuilds the panel clock string at most once per minute.
    private func updateClock() {
        let nowMs = Platform.services.wallClockMs
        let minute = Int(nowMs / 60_000)
        guard minute != clockMinute else { return }
        clockMinute = minute
        clockString = TimeFmt.clock(nowMs)
    }
}
