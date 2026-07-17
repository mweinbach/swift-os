import Foundation
import CoreGraphics

/// STUB — the file-manager subsystem replaces this with a real file manager app.
/// Keep the class name and both initializers EXACTLY; the desktop and shell use them.
final class FileManagerApp: OSApp {
    let initialPath: String

    init() { self.initialPath = "/home/user" }
    init(path: String) { self.initialPath = path }

    var title: String { "Files" }
    var preferredContentSize: CGSize { CGSize(width: 640, height: 430) }

    func draw(_ surface: Surface, in rect: CGRect) {
        surface.fill(rect, color: .windowBackground)
        surface.text("files: awaiting implementation",
                     at: CGPoint(x: rect.minX + 8, y: rect.minY + 8),
                     color: .panelText)
    }
}
