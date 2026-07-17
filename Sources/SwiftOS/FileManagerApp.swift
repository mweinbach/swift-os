import Foundation
import CoreGraphics

/// Files — a Linux-style (GNOME Files / Nautilus-like) file manager running on the
/// in-memory VFS. Toolbar with history nav + clickable breadcrumb, places sidebar,
/// sortable list view, and a status bar with transient messages.
///
/// Layout of the content rect: 46px toolbar on top, 24px status bar at the bottom,
/// a 170px sidebar on the left, and the main list filling the remainder. All hit
/// geometry is recomputed every `draw(_:in:)` and stored for event mapping.
final class FileManagerApp: OSApp {
    let initialPath: String

    // MARK: - Private types

    private enum SortKey { case name, size, modified }
    private enum NavButton { case back, forward, up, newFolder, delete }

    // MARK: - Layout constants

    private let toolbarHeight: CGFloat = 46
    private let sidebarWidth: CGFloat = 170
    private let statusHeight: CGFloat = 24
    private let headerHeight: CGFloat = 26
    private let rowHeight: CGFloat = 26
    private let iconSize: CGFloat = 16

    // MARK: - State

    private var currentPath: String
    private var history: [String]
    private var historyIndex: Int

    private var rawEntries: [VNode] = []
    private var entries: [VNode] = [] // directories first, then files, sorted
    private var sortKey: SortKey = .name
    private var sortAscending = true
    private var selectedName: String?
    private var scrollOffset: CGFloat = 0

    private var mousePoint: CGPoint?
    private var pressedButton: NavButton?
    private var statusMessage: String?
    private var statusMessageIsError = false
    private var statusMessageTTL: TimeInterval = 0
    private var lastClickName: String?
    private var lastClickTime: TimeInterval = 0
    private var reloadAccumulator: TimeInterval = 0

    // MARK: - Hit geometry (recomputed every draw)

    private var listRect: CGRect = .zero
    private var backRect: CGRect = .zero
    private var forwardRect: CGRect = .zero
    private var upRect: CGRect = .zero
    private var newFolderRect: CGRect = .zero
    private var deleteRect: CGRect = .zero
    private var breadcrumbHits: [(rect: CGRect, path: String)] = []
    private var sidebarHits: [(rect: CGRect, path: String)] = []
    private var nameHeaderRect: CGRect = .zero
    private var sizeHeaderRect: CGRect = .zero
    private var modifiedHeaderRect: CGRect = .zero

    // MARK: - Shared private constants

    private static let places: [(label: String, path: String)] = [
        ("Home", "/home/user"),
        ("File System", "/"),
        ("Projects", "/home/user/projects"),
        ("etc", "/etc"),
        ("Logs", "/var/log"),
        ("tmp", "/tmp"),
    ]
    private static let folderColor = Color.hex(0xE5A50A)
    private static let folderShade = Color.hex(0xB87F06)
    private static let fileColor = Color.hex(0xC0BFBC)
    private static let fileShade = Color.hex(0x8B8A87)

    private lazy var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM dd HH:mm"
        return f
    }()

    // MARK: - Init

    init() {
        self.initialPath = "/home/user"
        let start = FileManagerApp.resolveStartPath("/home/user")
        self.currentPath = start
        self.history = [start]
        self.historyIndex = 0
        reload()
    }

    init(path: String) {
        self.initialPath = path
        let start = FileManagerApp.resolveStartPath(path)
        self.currentPath = start
        self.history = [start]
        self.historyIndex = 0
        reload()
    }

    /// Falls back to /home/user (then /) when the requested path is not a directory.
    private static func resolveStartPath(_ path: String) -> String {
        let n = VFS.normalize(path, cwd: "/")
        if VFS.shared.isDirectory(n) { return n }
        if VFS.shared.isDirectory("/home/user") { return "/home/user" }
        return "/"
    }

    // MARK: - OSApp

    var title: String { "Files" }
    var preferredContentSize: CGSize { CGSize(width: 640, height: 430) }

    func tick(_ dt: TimeInterval) {
        if statusMessage != nil {
            statusMessageTTL -= dt
            if statusMessageTTL <= 0 { statusMessage = nil }
        }
        // Refresh twice a second so external changes (terminal, other apps) show up,
        // and so we notice if the current directory was deleted under us.
        reloadAccumulator += dt
        if reloadAccumulator >= 0.5 {
            reloadAccumulator = 0
            ensureCurrentDirectory()
            reload()
        }
    }

    // MARK: - Data

    private func joinPath(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    /// If the current directory no longer exists, walk up to the nearest existing ancestor.
    private func ensureCurrentDirectory() {
        var p = currentPath
        while p != "/" && !VFS.shared.isDirectory(p) {
            p = VFS.dirname(p)
        }
        if !VFS.shared.isDirectory(p) { p = "/" }
        if p != currentPath {
            currentPath = p
            selectedName = nil
            scrollOffset = 0
        }
    }

    private func reload() {
        do {
            rawEntries = try VFS.shared.list(currentPath)
        } catch {
            ensureCurrentDirectory()
            rawEntries = (try? VFS.shared.list(currentPath)) ?? []
        }
        applySort()
        if let sel = selectedName, !entries.contains(where: { $0.name == sel }) {
            selectedName = nil
        }
        clampScroll()
    }

    private func applySort() {
        func compare(_ a: VNode, _ b: VNode) -> Bool {
            switch sortKey {
            case .name:
                let c = a.name.localizedCaseInsensitiveCompare(b.name)
                if c == .orderedSame { return a.name < b.name }
                return sortAscending ? c == .orderedAscending : c == .orderedDescending
            case .size:
                if a.size != b.size { return sortAscending ? a.size < b.size : a.size > b.size }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .modified:
                if a.modified != b.modified {
                    return sortAscending ? a.modified < b.modified : a.modified > b.modified
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        let dirs = rawEntries.filter { $0.isDirectory }.sorted(by: compare)
        let files = rawEntries.filter { !$0.isDirectory }.sorted(by: compare)
        entries = dirs + files
    }

    private func clampScroll() {
        let contentH = CGFloat(entries.count) * rowHeight
        let maxScroll = max(0, contentH - listRect.height)
        scrollOffset = min(max(scrollOffset, 0), maxScroll)
    }

    private func scrollToSelection() {
        guard let name = selectedName,
              let idx = entries.firstIndex(where: { $0.name == name }) else { return }
        let top = CGFloat(idx) * rowHeight
        if top < scrollOffset {
            scrollOffset = top
        } else if top + rowHeight > scrollOffset + listRect.height {
            scrollOffset = top + rowHeight - listRect.height
        }
        clampScroll()
    }

    private func showMessage(_ text: String, isError: Bool) {
        statusMessage = text
        statusMessageIsError = isError
        statusMessageTTL = 4
    }

    // MARK: - Navigation & actions

    private func navigate(to path: String) {
        let n = VFS.normalize(path, cwd: currentPath)
        guard n != currentPath else { return }
        guard VFS.shared.isDirectory(n) else {
            if VFS.shared.exists(n) {
                showMessage(VFSError.notDirectory(path: n).description, isError: true)
            } else {
                showMessage(VFSError.notFound(path: n).description, isError: true)
            }
            return
        }
        currentPath = n
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(n)
        historyIndex = history.count - 1
        selectedName = nil
        scrollOffset = 0
        reload()
    }

    private func goBack() { jumpHistory(to: historyIndex - 1) }
    private func goForward() { jumpHistory(to: historyIndex + 1) }

    private func jumpHistory(to index: Int) {
        guard index >= 0 && index < history.count else { return }
        historyIndex = index
        currentPath = history[index]
        ensureCurrentDirectory()
        selectedName = nil
        scrollOffset = 0
        reload()
    }

    private func navigateUp() {
        guard currentPath != "/" else { return }
        navigate(to: VFS.dirname(currentPath))
    }

    private func openEntry(_ node: VNode) {
        let path = joinPath(currentPath, node.name)
        if node.isDirectory {
            navigate(to: path)
        } else {
            WindowManager.shared.open(app: TextEditorApp(path: path))
        }
    }

    private func openSelection() {
        guard let name = selectedName,
              let node = entries.first(where: { $0.name == name }) else { return }
        openEntry(node)
    }

    private func setSortKey(_ key: SortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
        applySort()
    }

    private func createFolder() {
        var name = "untitled folder"
        var n = 2
        while VFS.shared.exists(joinPath(currentPath, name)) {
            name = "untitled folder \(n)"
            n += 1
        }
        do {
            try VFS.shared.mkdir(joinPath(currentPath, name))
            reload()
            selectedName = name
            scrollToSelection()
            showMessage("Created \(name)", isError: false)
        } catch let error as VFSError {
            showMessage(error.description, isError: true)
        } catch {
            showMessage(error.localizedDescription, isError: true)
        }
    }

    private func deleteSelection() {
        guard let name = selectedName else { return }
        do {
            try VFS.shared.remove(joinPath(currentPath, name))
            selectedName = nil
            reload()
            showMessage("Deleted \(name)", isError: false)
        } catch let error as VFSError {
            showMessage(error.description, isError: true)
        } catch {
            showMessage(error.localizedDescription, isError: true)
        }
    }

    private func moveSelection(delta: Int) {
        guard !entries.isEmpty else { return }
        let idx = selectedName.flatMap { name in entries.firstIndex { $0.name == name } }
        let next: Int
        if let idx {
            next = min(max(idx + delta, 0), entries.count - 1)
        } else {
            next = delta > 0 ? 0 : entries.count - 1
        }
        selectedName = entries[next].name
        scrollToSelection()
    }

    // MARK: - Formatting

    private func formatSize(_ node: VNode) -> String {
        if node.isDirectory { return "--" }
        let size = node.size
        if size < 1024 { return "\(size) B" }
        let kb = Double(size) / 1024
        if kb < 1024 { return FileManagerApp.formatUnit(kb, "KB") }
        return FileManagerApp.formatUnit(kb / 1024, "MB")
    }

    private static func formatUnit(_ value: Double, _ unit: String) -> String {
        value < 10 ? String(format: "%.1f %@", value, unit) : String(format: "%.0f %@", value, unit)
    }

    private func truncate(_ s: Surface, _ str: String, maxWidth: CGFloat) -> String {
        if s.textSize(str).width <= maxWidth { return str }
        var out = str
        while !out.isEmpty && s.textSize(out + "...").width > maxWidth {
            out.removeLast()
        }
        return out + "..."
    }

    // MARK: - Drawing

    func draw(_ surface: Surface, in rect: CGRect) {
        let toolbar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: toolbarHeight)
        let status = CGRect(x: rect.minX, y: rect.maxY - statusHeight,
                            width: rect.width, height: statusHeight)
        let sidebar = CGRect(x: rect.minX, y: toolbar.maxY, width: sidebarWidth,
                             height: max(0, rect.height - toolbarHeight - statusHeight))
        let main = CGRect(x: sidebar.maxX, y: toolbar.maxY,
                          width: max(0, rect.width - sidebarWidth), height: sidebar.height)

        surface.fill(rect, color: .windowBackground)
        drawToolbar(surface, rect: toolbar)
        drawSidebar(surface, rect: sidebar)
        drawMainList(surface, rect: main)
        drawStatusBar(surface, rect: status)
    }

    private func drawToolbar(_ s: Surface, rect: CGRect) {
        s.fill(rect, color: .titleBar)
        s.line(from: CGPoint(x: rect.minX, y: rect.maxY - 0.5),
               to: CGPoint(x: rect.maxX, y: rect.maxY - 0.5), color: .windowBorder, width: 1)

        let btnSize: CGFloat = 28
        let by = rect.minY + (rect.height - btnSize) / 2
        backRect = CGRect(x: rect.minX + 10, y: by, width: btnSize, height: btnSize)
        forwardRect = backRect.offsetBy(dx: btnSize + 4, dy: 0)
        upRect = forwardRect.offsetBy(dx: btnSize + 4, dy: 0)

        drawNavButton(s, rect: backRect, kind: .back, enabled: historyIndex > 0)
        drawNavButton(s, rect: forwardRect, kind: .forward, enabled: historyIndex < history.count - 1)
        drawNavButton(s, rect: upRect, kind: .up, enabled: currentPath != "/")

        // Right-aligned action buttons.
        let newFolderW = s.textSize("New Folder").width + 22
        let deleteW = s.textSize("Delete").width + 22
        deleteRect = CGRect(x: rect.maxX - 10 - deleteW, y: by, width: deleteW, height: btnSize)
        newFolderRect = CGRect(x: deleteRect.minX - 8 - newFolderW, y: by, width: newFolderW, height: btnSize)
        drawActionButton(s, rect: newFolderRect, label: "New Folder", kind: .newFolder, enabled: true)
        drawActionButton(s, rect: deleteRect, label: "Delete", kind: .delete, enabled: selectedName != nil)

        drawBreadcrumb(s, from: upRect.maxX + 10, to: newFolderRect.minX - 10,
                       y: rect.minY, height: rect.height)
    }

    private func drawNavButton(_ s: Surface, rect: CGRect, kind: NavButton, enabled: Bool) {
        let hovered = enabled && (mousePoint.map { rect.contains($0) } ?? false)
        let pressed = hovered && pressedButton == kind
        if pressed {
            s.fill(rect.insetBy(dx: 1, dy: 1), color: .black.withAlpha(0.3))
        } else if hovered {
            s.fill(rect.insetBy(dx: 1, dy: 1), color: .white.withAlpha(0.08))
        }
        let color: Color = enabled ? .panelText : .darkGray
        let cx = rect.midX, cy = rect.midY
        switch kind {
        case .back:
            s.line(from: CGPoint(x: cx + 3.5, y: cy - 5), to: CGPoint(x: cx - 3.5, y: cy), color: color, width: 1.6)
            s.line(from: CGPoint(x: cx - 3.5, y: cy), to: CGPoint(x: cx + 3.5, y: cy + 5), color: color, width: 1.6)
        case .forward:
            s.line(from: CGPoint(x: cx - 3.5, y: cy - 5), to: CGPoint(x: cx + 3.5, y: cy), color: color, width: 1.6)
            s.line(from: CGPoint(x: cx + 3.5, y: cy), to: CGPoint(x: cx - 3.5, y: cy + 5), color: color, width: 1.6)
        case .up:
            s.line(from: CGPoint(x: cx, y: cy + 5), to: CGPoint(x: cx, y: cy - 4), color: color, width: 1.6)
            s.line(from: CGPoint(x: cx - 4, y: cy - 1), to: CGPoint(x: cx, y: cy - 5), color: color, width: 1.6)
            s.line(from: CGPoint(x: cx + 4, y: cy - 1), to: CGPoint(x: cx, y: cy - 5), color: color, width: 1.6)
        default:
            break
        }
    }

    private func drawActionButton(_ s: Surface, rect: CGRect, label: String, kind: NavButton, enabled: Bool) {
        let hovered = enabled && (mousePoint.map { rect.contains($0) } ?? false)
        let pressed = hovered && pressedButton == kind
        s.fill(rect, color: enabled ? .titleBarFocused : .titleBarFocused.withAlpha(0.45))
        if pressed {
            s.fill(rect, color: .black.withAlpha(0.28)) // pressed: darken
        } else if hovered {
            s.fill(rect, color: .white.withAlpha(0.10)) // hover: lighten
        }
        s.stroke(rect, color: .windowBorder)
        let ts = s.textSize(label)
        s.text(label, at: CGPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2),
               color: enabled ? .panelText : .darkGray)
    }

    private func drawBreadcrumb(_ s: Surface, from x0: CGFloat, to x1: CGFloat, y: CGFloat, height: CGFloat) {
        breadcrumbHits = []
        let width = x1 - x0
        guard width > 20 else { return }

        var segments: [(label: String, path: String)] = [("/", "/")]
        if currentPath != "/" {
            var built = ""
            for comp in currentPath.split(separator: "/") {
                built += "/" + comp
                segments.append((String(comp), built))
            }
        }

        let clip = CGRect(x: x0, y: y, width: width, height: height)
        s.pushClip(clip)
        let textH = s.textSize("/").height
        var x = x0
        for (i, seg) in segments.enumerated() {
            if i > 0 {
                let sw = s.textSize("/").width
                s.text("/", at: CGPoint(x: x, y: y + (height - textH) / 2), color: .darkGray)
                x += sw + 4
            }
            let tw = s.textSize(seg.label).width
            let segRect = CGRect(x: x - 3, y: y + (height - 24) / 2, width: tw + 6, height: 24)
            let isCurrent = i == segments.count - 1
            let hovered = mousePoint.map { segRect.contains($0) } ?? false
            if isCurrent {
                s.fill(segRect, color: .white.withAlpha(0.07))
            } else if hovered {
                s.fill(segRect, color: .white.withAlpha(0.10))
            }
            s.text(seg.label, at: CGPoint(x: x, y: y + (height - textH) / 2),
                   color: isCurrent ? .titleText : .panelText)
            breadcrumbHits.append((segRect, seg.path))
            x += tw + 7
            if x > x1 { break }
        }
        s.popClip()
    }

    private func drawSidebar(_ s: Surface, rect: CGRect) {
        s.fill(rect, color: .panel)
        s.line(from: CGPoint(x: rect.maxX - 0.5, y: rect.minY),
               to: CGPoint(x: rect.maxX - 0.5, y: rect.maxY), color: .windowBorder, width: 1)
        sidebarHits = []

        var y = rect.minY + 12
        s.text("Places", at: CGPoint(x: rect.minX + 12, y: y), color: .darkGray)
        y += s.textSize("Places").height + 10

        let rowH: CGFloat = 28
        let textH = s.textSize("Ag").height
        for place in FileManagerApp.places {
            let rowRect = CGRect(x: rect.minX + 4, y: y, width: rect.width - 8, height: rowH)
            let selected = place.path == currentPath ||
                (place.path != "/" && currentPath.hasPrefix(place.path + "/"))
            let hovered = mousePoint.map { rowRect.contains($0) } ?? false
            if selected {
                s.fill(rowRect, color: .accent.withAlpha(0.35))
            } else if hovered {
                s.fill(rowRect, color: .white.withAlpha(0.06))
            }
            drawFolderIcon(s, x: rowRect.minX + 8, y: rowRect.minY + (rowH - iconSize) / 2)
            s.text(place.label, at: CGPoint(x: rowRect.minX + 32, y: rowRect.minY + (rowH - textH) / 2),
                   color: selected ? .titleText : .panelText)
            sidebarHits.append((rowRect, place.path))
            y += rowH
            if y + rowH > rect.maxY { break }
        }
    }

    private func columnLayout(width: CGFloat) -> (nameWidth: CGFloat, sizeWidth: CGFloat, modifiedWidth: CGFloat) {
        let sizeW: CGFloat = 84
        let modW: CGFloat = 128
        let nameW = max(60, width - sizeW - modW - 10)
        return (nameW, sizeW, modW)
    }

    private func drawMainList(_ s: Surface, rect: CGRect) {
        let header = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)
        listRect = CGRect(x: rect.minX, y: header.maxY, width: rect.width,
                          height: max(0, rect.height - headerHeight))
        clampScroll()

        // Header
        s.fill(header, color: .black.withAlpha(0.18))
        s.line(from: CGPoint(x: header.minX, y: header.maxY - 0.5),
               to: CGPoint(x: header.maxX, y: header.maxY - 0.5), color: .windowBorder, width: 1)

        let cols = columnLayout(width: rect.width)
        nameHeaderRect = CGRect(x: rect.minX, y: header.minY, width: cols.nameWidth, height: header.height)
        sizeHeaderRect = CGRect(x: nameHeaderRect.maxX, y: header.minY, width: cols.sizeWidth, height: header.height)
        modifiedHeaderRect = CGRect(x: sizeHeaderRect.maxX, y: header.minY, width: cols.modifiedWidth, height: header.height)

        drawHeaderLabel(s, "Name", rect: nameHeaderRect, key: .name,
                        rightAligned: false, textX: rect.minX + 32)
        drawHeaderLabel(s, "Size", rect: sizeHeaderRect, key: .size,
                        rightAligned: true, textX: sizeHeaderRect.minX + 8)
        drawHeaderLabel(s, "Modified", rect: modifiedHeaderRect, key: .modified,
                        rightAligned: false, textX: modifiedHeaderRect.minX + 8)

        // Rows
        let textH = s.textSize("Ag").height
        s.pushClip(listRect)
        for (i, node) in entries.enumerated() {
            let rowY = listRect.minY + CGFloat(i) * rowHeight - scrollOffset
            if rowY + rowHeight < listRect.minY { continue }
            if rowY > listRect.maxY { break }
            let rowRect = CGRect(x: listRect.minX, y: rowY, width: listRect.width, height: rowHeight)
            let isSelected = node.name == selectedName
            let hovered = mousePoint.map { listRect.contains($0) && rowRect.contains($0) } ?? false
            if isSelected {
                s.fill(rowRect, color: .selection)
            } else if hovered {
                s.fill(rowRect, color: .white.withAlpha(0.06))
            } else if i % 2 == 1 {
                s.fill(rowRect, color: .white.withAlpha(0.035)) // zebra striping
            }

            let iconY = rowRect.minY + (rowHeight - iconSize) / 2
            if node.isDirectory {
                drawFolderIcon(s, x: rowRect.minX + 8, y: iconY)
            } else {
                drawFileIcon(s, x: rowRect.minX + 8, y: iconY)
            }

            let textY = rowRect.minY + (rowHeight - textH) / 2
            let nameColor: Color = isSelected ? .white : (node.isDirectory ? .titleText : .panelText)
            let name = truncate(s, node.name, maxWidth: max(20, cols.nameWidth - 40))
            s.text(name, at: CGPoint(x: rowRect.minX + 32, y: textY), color: nameColor)

            let sizeStr = formatSize(node)
            let sizeW = s.textSize(sizeStr).width
            s.text(sizeStr, at: CGPoint(x: sizeHeaderRect.maxX - 12 - sizeW, y: textY),
                   color: isSelected ? .white : .gray)

            let dateStr = dateFormatter.string(from: node.modified)
            s.text(dateStr, at: CGPoint(x: modifiedHeaderRect.minX + 8, y: textY),
                   color: isSelected ? .white : .gray)
        }
        if entries.isEmpty {
            let msg = "Folder is Empty"
            let ts = s.textSize(msg)
            s.text(msg, at: CGPoint(x: listRect.midX - ts.width / 2, y: listRect.minY + 20),
                   color: .darkGray)
        }
        s.popClip()

        drawScrollbar(s)
    }

    private func drawHeaderLabel(_ s: Surface, _ label: String, rect: CGRect, key: SortKey,
                                 rightAligned: Bool, textX: CGFloat) {
        let hovered = mousePoint.map { rect.contains($0) } ?? false
        if hovered { s.fill(rect, color: .white.withAlpha(0.05)) }
        let ts = s.textSize(label)
        let x = rightAligned ? rect.maxX - 12 - ts.width : textX
        s.text(label, at: CGPoint(x: x, y: rect.minY + (rect.height - ts.height) / 2),
               color: sortKey == key ? .titleText : .gray)
        if sortKey == key {
            // Sort direction chevron (up = ascending, down = descending).
            let ax = rightAligned ? x - 9 : x + ts.width + 7
            let ay = rect.midY
            if sortAscending {
                s.line(from: CGPoint(x: ax - 3.5, y: ay + 2.5), to: CGPoint(x: ax, y: ay - 2.5), color: .accent, width: 1.4)
                s.line(from: CGPoint(x: ax, y: ay - 2.5), to: CGPoint(x: ax + 3.5, y: ay + 2.5), color: .accent, width: 1.4)
            } else {
                s.line(from: CGPoint(x: ax - 3.5, y: ay - 2.5), to: CGPoint(x: ax, y: ay + 2.5), color: .accent, width: 1.4)
                s.line(from: CGPoint(x: ax, y: ay + 2.5), to: CGPoint(x: ax + 3.5, y: ay - 2.5), color: .accent, width: 1.4)
            }
        }
    }

    private func drawScrollbar(_ s: Surface) {
        let contentH = CGFloat(entries.count) * rowHeight
        guard contentH > listRect.height, listRect.height > 0 else { return }
        let trackW: CGFloat = 4
        let trackX = listRect.maxX - trackW - 3
        s.fill(CGRect(x: trackX, y: listRect.minY + 2, width: trackW, height: listRect.height - 4),
               color: .white.withAlpha(0.05))
        let maxScroll = contentH - listRect.height
        let thumbH = max(20, (listRect.height - 4) * listRect.height / contentH)
        let travel = listRect.height - 4 - thumbH
        let thumbY = listRect.minY + 2 + (maxScroll > 0 ? scrollOffset / maxScroll : 0) * travel
        s.fill(CGRect(x: trackX, y: thumbY, width: trackW, height: thumbH),
               color: .white.withAlpha(0.22))
    }

    private func drawStatusBar(_ s: Surface, rect: CGRect) {
        s.fill(rect, color: .panel)
        s.line(from: CGPoint(x: rect.minX, y: rect.minY + 0.5),
               to: CGPoint(x: rect.maxX, y: rect.minY + 0.5), color: .windowBorder, width: 1)
        let textH = s.textSize("Ag").height
        let textY = rect.minY + (rect.height - textH) / 2
        let count = entries.count == 1 ? "1 item" : "\(entries.count) items"
        s.text(count, at: CGPoint(x: rect.minX + 10, y: textY), color: .gray)
        if let msg = statusMessage {
            let tw = s.textSize(msg).width
            s.text(msg, at: CGPoint(x: rect.maxX - 10 - tw, y: textY),
                   color: statusMessageIsError ? .red : .gray)
        }
    }

    // MARK: - Icons (16px, drawn from rects)

    /// Yellow-ish folder: small tab on top-left, body below, subtle bottom shading.
    private func drawFolderIcon(_ s: Surface, x: CGFloat, y: CGFloat) {
        let size = iconSize
        let tabW = size * 0.45
        s.fill(CGRect(x: x, y: y, width: tabW, height: 4), color: FileManagerApp.folderShade)
        s.fill(CGRect(x: x, y: y + 3, width: size, height: size - 3), color: FileManagerApp.folderColor)
        s.fill(CGRect(x: x, y: y + size - 3, width: size, height: 3),
               color: FileManagerApp.folderShade.withAlpha(0.55))
    }

    /// Gray document with a folded top-right corner and text lines.
    private func drawFileIcon(_ s: Surface, x: CGFloat, y: CGFloat) {
        let size = iconSize
        let w = size * 0.75
        let ix = x + (size - w) / 2
        let fold: CGFloat = 4
        s.fill(CGRect(x: ix, y: y, width: w - fold, height: fold), color: FileManagerApp.fileColor)
        s.fill(CGRect(x: ix, y: y + fold, width: w, height: size - fold), color: FileManagerApp.fileColor)
        s.fill(CGRect(x: ix + w - fold, y: y, width: fold, height: fold), color: FileManagerApp.fileShade)
        s.fill(CGRect(x: ix + 2, y: y + 7, width: w - 4, height: 1), color: FileManagerApp.fileShade)
        s.fill(CGRect(x: ix + 2, y: y + 10, width: w - 4, height: 1), color: FileManagerApp.fileShade)
        s.fill(CGRect(x: ix + 2, y: y + 13, width: w - 6, height: 1), color: FileManagerApp.fileShade)
    }

    // MARK: - Events

    func handle(_ event: OSEvent) {
        switch event {
        case .mouseDown(let p): mouseDown(p)
        case .mouseUp(let p): mouseUp(p)
        case .mouseMoved(let p), .mouseDragged(let p): mousePoint = p
        case .scrollWheel(let p, _, let dy): scrollWheel(p, deltaY: dy)
        case .keyDown(let k): keyDown(k)
        default: break // rightMouseDown: no action; keyUp ignored
        }
    }

    private func mouseDown(_ p: CGPoint) {
        // Toolbar buttons: press now, act on release inside the same button.
        let buttons: [(NavButton, CGRect, Bool)] = [
            (.back, backRect, historyIndex > 0),
            (.forward, forwardRect, historyIndex < history.count - 1),
            (.up, upRect, currentPath != "/"),
            (.newFolder, newFolderRect, true),
            (.delete, deleteRect, selectedName != nil),
        ]
        for (kind, rect, enabled) in buttons where enabled && rect.contains(p) {
            pressedButton = kind
            return
        }
        for hit in breadcrumbHits where hit.rect.contains(p) {
            navigate(to: hit.path)
            return
        }
        for hit in sidebarHits where hit.rect.contains(p) {
            navigate(to: hit.path)
            return
        }
        if nameHeaderRect.contains(p) { setSortKey(.name); return }
        if sizeHeaderRect.contains(p) { setSortKey(.size); return }
        if modifiedHeaderRect.contains(p) { setSortKey(.modified); return }

        guard listRect.contains(p) else { return }
        let row = Int((p.y - listRect.minY + scrollOffset) / rowHeight)
        guard row >= 0 && row < entries.count else {
            selectedName = nil // clicked empty space: clear selection
            return
        }
        let node = entries[row]
        let now = Date().timeIntervalSince1970
        if node.name == lastClickName && now - lastClickTime < 0.35 {
            // Double-click: open directory or file.
            lastClickName = nil
            lastClickTime = 0
            selectedName = node.name
            openEntry(node)
            return
        }
        selectedName = node.name
        lastClickName = node.name
        lastClickTime = now
    }

    private func mouseUp(_ p: CGPoint) {
        guard let kind = pressedButton else { return }
        pressedButton = nil
        let rect: CGRect
        let enabled: Bool
        switch kind {
        case .back: rect = backRect; enabled = historyIndex > 0
        case .forward: rect = forwardRect; enabled = historyIndex < history.count - 1
        case .up: rect = upRect; enabled = currentPath != "/"
        case .newFolder: rect = newFolderRect; enabled = true
        case .delete: rect = deleteRect; enabled = selectedName != nil
        }
        guard enabled, rect.contains(p) else { return }
        switch kind {
        case .back: goBack()
        case .forward: goForward()
        case .up: navigateUp()
        case .newFolder: createFolder()
        case .delete: deleteSelection()
        }
    }

    private func scrollWheel(_ p: CGPoint, deltaY: CGFloat) {
        guard listRect.contains(p) else { return }
        scrollOffset -= deltaY * 2.5
        clampScroll()
    }

    private func keyDown(_ k: KeyEvent) {
        switch k.keyCode {
        case 126: moveSelection(delta: -1) // Up
        case 125: moveSelection(delta: 1)  // Down
        case 36: openSelection()           // Return
        case 51: navigateUp()              // Backspace
        default: break
        }
    }
}
