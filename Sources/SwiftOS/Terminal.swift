import Foundation
import CoreGraphics

/// STUB — the terminal subsystem replaces this with a real terminal emulator app.
/// Keep the class name and `init()` EXACTLY; the desktop and demo mode use them.
final class TerminalApp: OSApp {
    init() {}

    var title: String { "Terminal" }
    var preferredContentSize: CGSize { CGSize(width: 720, height: 440) }

    func draw(_ surface: Surface, in rect: CGRect) {
        surface.fill(rect, color: .terminalBackground)
        surface.text("swift-term: awaiting implementation",
                     at: CGPoint(x: rect.minX + 8, y: rect.minY + 8),
                     color: .terminalText)
    }
}
