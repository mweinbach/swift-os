import Foundation
import CoreGraphics

/// STUB — the text-editor subsystem replaces this with a real text editor app.
/// Keep the class name and both initializers EXACTLY; the desktop, file manager,
/// and shell use them.
final class TextEditorApp: OSApp {
    let path: String?

    init() { self.path = nil }
    init(path: String) { self.path = path }

    var title: String {
        if let path { return VFS.basename(path) }
        return "Text Editor"
    }
    var preferredContentSize: CGSize { CGSize(width: 660, height: 470) }

    func draw(_ surface: Surface, in rect: CGRect) {
        surface.fill(rect, color: .windowBackground)
        surface.text("editor: awaiting implementation",
                     at: CGPoint(x: rect.minX + 8, y: rect.minY + 8),
                     color: .panelText)
    }
}
