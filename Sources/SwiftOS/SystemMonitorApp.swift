import Foundation
import CoreGraphics

/// STUB — the system-monitor subsystem replaces this with a real process/
/// performance monitor app. Keep the class name and `init()` EXACTLY.
final class SystemMonitorApp: OSApp {
    init() {}

    var title: String { "System Monitor" }
    var preferredContentSize: CGSize { CGSize(width: 520, height: 470) }

    func draw(_ surface: Surface, in rect: CGRect) {
        surface.fill(rect, color: .windowBackground)
        surface.text("monitor: awaiting implementation",
                     at: CGPoint(x: rect.minX + 8, y: rect.minY + 8),
                     color: .panelText)
    }
}
