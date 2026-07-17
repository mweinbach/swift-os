import Foundation
import CoreGraphics

/// STUB — the desktop-environment subsystem replaces this whole file with the real
/// implementation (boot sequence, wallpaper, icons, top panel, taskbar).
/// Keep this public API EXACTLY; WindowManager calls it every frame.
final class Desktop {
    static let shared = Desktop()

    /// false while the boot sequence is on screen; WindowManager hides windows until true.
    var bootFinished = true

    private init() {}

    /// Full-screen draw: wallpaper + desktop icons, or the boot console while !bootFinished.
    func draw(_ surface: Surface) {
        surface.fill(CGRect(origin: .zero, size: surface.size), color: .desktopBottom)
    }

    /// Drawn ABOVE all windows: top panel + bottom taskbar.
    func drawOverlay(_ surface: Surface) {}

    /// Returns true when the event was consumed (panel/taskbar/icon/menu hit).
    @discardableResult
    func handle(_ event: OSEvent) -> Bool { false }

    func tick(_ dt: TimeInterval) {}
}
