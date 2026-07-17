/// A gedit-style plain-text editor: line-number gutter, soft-wrapped monospace
/// editing surface, blinking block cursor, and a status bar with save feedback.
/// The buffer is stored as [Character] arrays so all cursor math is index-safe
/// for arbitrary unicode (ASCII editing is the primary use case).
///
/// Embedded Swift port: OSApp is a base class (override, not protocol
/// conformance) and the VFS throws typed `VFSError`.
final class TextEditorApp: OSApp {
    /// Save location. nil for a fresh document until the first save, which picks
    /// /home/user/untitled.txt (auto-incrementing untitled-2.txt, ... if taken).
    private(set) var path: String?

    // MARK: - Buffer state

    private var lines: [[Character]] = [[]]
    private var cursorLine = 0
    private var cursorCol = 0            // in Characters, 0...lines[cursorLine].count
    private var goalCol: Int?            // remembered visual column for up/down movement
    private var dirty = false
    private var scrollRow = 0            // first visible visual (wrapped) row
    private var dragging = false
    private var scrollAccumulator: CGFloat = 0

    // MARK: - Transient UI state

    private var blinkTime: TimeInterval = 0
    private var time: TimeInterval = 0
    private var message: String?
    private var messageIsError = false
    private var messageExpiry: TimeInterval = 0
    private var layout = Layout()

    private struct Layout {
        var rect: CGRect = .zero
        var charW: CGFloat = 8
        var lineH: CGFloat = 17
        var cols = 78                    // wrap width in characters
        var visibleRows = 24
        var totalRows = 1
        var textLeft: CGFloat = 0
        var textTop: CGFloat = 0
        var statusTop: CGFloat = 0
        var showScrollbar = false
    }

    private static let gutterWidth: CGFloat = 46
    private static let statusBarHeight: CGFloat = 24
    private static let homeDirectory = "/home/user"

    private static let defaultSnippet: [[Character]] = [
        "// Welcome to the SwiftOS text editor",
        "// Ctrl+S (or Cmd+S) saves this file.",
        "",
        "import Foundation",
        "",
        "func greet(_ name: String) {",
        "    print(\"Hello, \\(name)!\")",
        "}",
        "",
        "greet(\"world\")",
    ].map { Array($0) }

    // MARK: - Init

    override init() {
        self.path = nil
        self.lines = Self.defaultSnippet
        super.init()
    }

    /// New designated signature (the OSApp base only has `init()`), so no `override`.
    init(path: String) {
        let normalized = VFS.normalize(path, cwd: Self.homeDirectory)
        self.path = normalized
        super.init()
        load(normalized)
    }

    override var title: String {
        let base = path.map { VFS.basename($0) } ?? "Text Editor"
        return dirty ? base + " *" : base
    }

    override var preferredContentSize: CGSize { CGSize(width: 660, height: 470) }

    // MARK: - File I/O

    private func load(_ path: String) {
        cursorLine = 0
        cursorCol = 0
        scrollRow = 0
        goalCol = nil
        dirty = false
        if VFS.shared.isDirectory(path) {
            lines = [[]]
            showMessage(VFSError.isDirectory(path: path).description, isError: true)
            return
        }
        do {
            let content = try VFS.shared.read(path)
            let split = content.split(separator: "\n", omittingEmptySubsequences: false)
            lines = split.map { substring -> [Character] in
                var chars = Array(substring)
                if chars.last == "\r" { chars.removeLast() } // tolerate CRLF files
                return chars
            }
            if lines.isEmpty { lines = [[]] }
        } catch {
            // Typed throws: `error` is VFSError.
            switch error {
            case .notFound:
                lines = [[]] // new file — saving creates it
            default:
                lines = [[]]
                showMessage(error.description, isError: true)
            }
        }
    }

    private func save() {
        let target = path ?? Self.nextUntitledPath()
        do {
            try VFS.shared.write(target, contents: bufferText())
            if path == nil { path = target }
            dirty = false
            showMessage("Saved", isError: false)
        } catch {
            showMessage(error.description, isError: true)
        }
    }

    private func bufferText() -> String {
        lines.map { String($0) }.joined(separator: "\n")
    }

    private static func nextUntitledPath() -> String {
        var candidate = homeDirectory + "/untitled.txt"
        var n = 2
        while VFS.shared.exists(candidate) {
            candidate = homeDirectory + "/untitled-\(n).txt"
            n += 1
        }
        return candidate
    }

    // MARK: - Wrapping model

    /// Number of visual rows a logical line occupies at the given wrap width.
    private func visualRows(for line: [Character], cols: Int) -> Int {
        max(1, (line.count + cols - 1) / cols)
    }

    private func totalVisualRows(cols: Int) -> Int {
        lines.reduce(0) { $0 + visualRows(for: $1, cols: cols) }
    }

    /// Maps a character column to (wrapped chunk index, column within chunk).
    /// A column sitting exactly on a wrap boundary belongs to the END of the
    /// previous chunk, so the cursor renders at the end of that visual row.
    private func chunkAndOffset(col: Int, line: [Character], cols: Int) -> (chunk: Int, offset: Int) {
        if col > 0, col % cols == 0 {
            return (col / cols - 1, cols)
        }
        return (col / cols, col % cols)
    }

    /// Maps a visual row index back to (logical line, chunk within that line).
    private func locate(visualRow row: Int, cols: Int) -> (line: Int, chunk: Int) {
        var r = 0
        for i in lines.indices {
            let count = visualRows(for: lines[i], cols: cols)
            if row < r + count { return (i, row - r) }
            r += count
        }
        let last = lines.count - 1
        return (last, visualRows(for: lines[last], cols: cols) - 1)
    }

    private func cursorVisualRow(cols: Int) -> Int {
        var row = 0
        for i in 0..<cursorLine { row += visualRows(for: lines[i], cols: cols) }
        return row + chunkAndOffset(col: cursorCol, line: lines[cursorLine], cols: cols).chunk
    }

    private func clampScroll() {
        let maxScroll = max(0, totalVisualRows(cols: layout.cols) - layout.visibleRows)
        scrollRow = max(0, min(scrollRow, maxScroll))
    }

    private func ensureCursorVisible() {
        let row = cursorVisualRow(cols: layout.cols)
        if row < scrollRow {
            scrollRow = row
        } else if row >= scrollRow + layout.visibleRows {
            scrollRow = row - layout.visibleRows + 1
        }
        clampScroll()
    }

    // MARK: - Editing operations

    private func markEdited() {
        dirty = true
        goalCol = nil
        blinkTime = 0
    }

    private func insertText(_ s: String) {
        guard !s.isEmpty else { return }
        for ch in s {
            lines[cursorLine].insert(ch, at: cursorCol)
            cursorCol += 1
        }
        markEdited()
    }

    private func splitLine() {
        let line = lines[cursorLine]
        lines[cursorLine] = Array(line[..<cursorCol])
        lines.insert(Array(line[cursorCol...]), at: cursorLine + 1)
        cursorLine += 1
        cursorCol = 0
        markEdited()
    }

    private func backspace() {
        if cursorCol > 0 {
            lines[cursorLine].remove(at: cursorCol - 1)
            cursorCol -= 1
        } else if cursorLine > 0 {
            let previous = cursorLine - 1
            cursorCol = lines[previous].count
            lines[previous].append(contentsOf: lines[cursorLine])
            lines.remove(at: cursorLine)
            cursorLine = previous
        } else {
            return
        }
        markEdited()
    }

    private func forwardDelete() {
        if cursorCol < lines[cursorLine].count {
            lines[cursorLine].remove(at: cursorCol)
        } else if cursorLine < lines.count - 1 {
            lines[cursorLine].append(contentsOf: lines[cursorLine + 1])
            lines.remove(at: cursorLine + 1)
        } else {
            return
        }
        markEdited()
    }

    // MARK: - Cursor movement

    private func moveLeft() {
        if cursorCol > 0 {
            cursorCol -= 1
        } else if cursorLine > 0 {
            cursorLine -= 1
            cursorCol = lines[cursorLine].count
        }
        goalCol = nil
        blinkTime = 0
    }

    private func moveRight() {
        if cursorCol < lines[cursorLine].count {
            cursorCol += 1
        } else if cursorLine < lines.count - 1 {
            cursorLine += 1
            cursorCol = 0
        }
        goalCol = nil
        blinkTime = 0
    }

    /// Moves one visual row up (direction -1) or down (+1), honoring soft wrap
    /// and the remembered goal column.
    private func moveVertical(_ direction: Int) {
        let cols = layout.cols
        let line = lines[cursorLine]
        let (chunk, offset) = chunkAndOffset(col: cursorCol, line: line, cols: cols)
        let goal = goalCol ?? offset
        if direction < 0 {
            if chunk > 0 {
                cursorCol = min((chunk - 1) * cols + goal, line.count)
            } else if cursorLine > 0 {
                cursorLine -= 1
                let previous = lines[cursorLine]
                let lastChunk = visualRows(for: previous, cols: cols) - 1
                cursorCol = min(lastChunk * cols + goal, previous.count)
            }
        } else {
            let rowCount = visualRows(for: line, cols: cols)
            if chunk < rowCount - 1 {
                cursorCol = min((chunk + 1) * cols + goal, line.count)
            } else if cursorLine < lines.count - 1 {
                cursorLine += 1
                cursorCol = min(goal, lines[cursorLine].count)
            }
        }
        goalCol = goal
        blinkTime = 0
    }

    private func moveHome() {
        cursorCol = 0
        goalCol = nil
        blinkTime = 0
    }

    private func moveEnd() {
        cursorCol = lines[cursorLine].count
        goalCol = nil
        blinkTime = 0
    }

    private func pageVertical(_ direction: Int) {
        let rows = max(1, layout.visibleRows - 1)
        for _ in 0..<rows { moveVertical(direction) }
    }

    // MARK: - Input

    override func handle(_ event: OSEvent) {
        switch event {
        case .keyDown(let key):
            handleKey(key)
        case .mouseDown(let point):
            if point.y < layout.statusTop {
                dragging = true
                positionCursor(at: point)
            }
        case .mouseDragged(let point):
            if dragging { positionCursor(at: point) }
        case .mouseUp:
            dragging = false
        case .scrollWheel(let point, _, let deltaY):
            if layout.rect.contains(point) { handleScroll(deltaY: deltaY) }
        default:
            break
        }
    }

    private func handleKey(_ key: KeyEvent) {
        // Ctrl+S / Cmd+S (S has keyCode 1) saves.
        if key.keyCode == 1, key.modifiers.contains(.command) || key.modifiers.contains(.control) {
            save()
            return
        }
        if key.modifiers.contains(.command) { return } // other Cmd combos are not ours
        switch key.keyCode {
        case 36: splitLine()          // Return
        case 51: backspace()          // Backspace
        case 117: forwardDelete()     // Forward-Delete
        case 123: moveLeft()          // Left
        case 124: moveRight()         // Right
        case 125: moveVertical(-1)    // Up
        case 126: moveVertical(1)     // Down
        case 115: moveHome()          // Home
        case 119: moveEnd()           // End
        case 116: pageVertical(-1)    // PageUp
        case 121: pageVertical(1)     // PageDown
        case 48: insertText("    ")   // Tab inserts 4 spaces
        default:
            if key.modifiers.contains(.control) { return }
            insertCharacters(key.characters)
        }
        ensureCursorVisible()
    }

    private func insertCharacters(_ characters: String) {
        guard let first = characters.unicodeScalars.first else { return }
        // Reject control characters and the private-use area (special keys).
        guard first.value >= 0x20, first.value != 0x7F,
              !(0xE000...0xF8FF).contains(first.value) else { return }
        insertText(characters)
    }

    private func positionCursor(at point: CGPoint) {
        let l = layout
        guard l.rect.width > 0, l.totalRows > 0 else { return }
        var p = point
        let right = l.rect.maxX - (l.showScrollbar ? 10 : 0)
        p.x = min(max(p.x, l.rect.minX), max(l.rect.minX, right))
        p.y = min(max(p.y, l.rect.minY), max(l.rect.minY, l.statusTop - 1))
        let rowOffset = max(0, Int((p.y - l.textTop) / l.lineH))
        let visualRow = max(0, min(l.totalRows - 1, scrollRow + rowOffset))
        let colX = p.x < l.textLeft ? 0 : max(0, Int((p.x - l.textLeft) / l.charW + 0.5))
        let (line, chunk) = locate(visualRow: visualRow, cols: l.cols)
        cursorLine = line
        cursorCol = min(lines[line].count, chunk * l.cols + colX)
        goalCol = nil
        blinkTime = 0
    }

    private func handleScroll(deltaY: CGFloat) {
        scrollAccumulator += deltaY
        let pointsPerRow: CGFloat = 4
        var rows = 0
        while scrollAccumulator >= pointsPerRow { rows += 1; scrollAccumulator -= pointsPerRow }
        while scrollAccumulator <= -pointsPerRow { rows -= 1; scrollAccumulator += pointsPerRow }
        if rows != 0 {
            scrollRow -= rows
            clampScroll()
        }
    }

    // MARK: - Tick

    override func tick(_ dt: TimeInterval) {
        time += dt
        blinkTime += dt
        if message != nil, time >= messageExpiry { message = nil }
    }

    private var blinkVisible: Bool {
        blinkTime.truncatingRemainder(dividingBy: 1.0) < 0.6
    }

    private func showMessage(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
        messageExpiry = time + (isError ? 6 : 3)
    }

    // MARK: - Drawing

    override func draw(_ surface: Surface, in rect: CGRect) {
        surface.fill(rect, color: .windowBackground)

        // Layout: gutter | text area (optional scrollbar on its right) / status bar.
        let metrics = surface.textSize("M")
        let charW = max(1, metrics.width)
        let lineH = max(1, metrics.height)
        let statusTop = rect.maxY - Self.statusBarHeight
        let gutterRight = rect.minX + Self.gutterWidth
        let textLeft = gutterRight + 6
        let textTop = rect.minY + 3
        let visibleRows = max(1, Int((statusTop - 3 - textTop) / lineH))

        var cols = max(1, Int((rect.maxX - 3 - textLeft) / charW))
        var totalRows = totalVisualRows(cols: cols)
        var showScrollbar = totalRows > visibleRows
        if showScrollbar {
            cols = max(1, Int((rect.maxX - 11 - textLeft) / charW))
            totalRows = totalVisualRows(cols: cols)
            showScrollbar = totalRows > visibleRows
        }

        let previousSize = layout.rect.size
        layout = Layout(rect: rect, charW: charW, lineH: lineH, cols: cols,
                        visibleRows: visibleRows, totalRows: totalRows,
                        textLeft: textLeft, textTop: textTop, statusTop: statusTop,
                        showScrollbar: showScrollbar)
        if previousSize != rect.size { ensureCursorVisible() } else { clampScroll() }

        let editHeight = statusTop - rect.minY

        // Gutter background and separator.
        surface.fill(CGRect(x: rect.minX, y: rect.minY, width: Self.gutterWidth, height: editHeight),
                     color: .black.withAlpha(0.18))

        // Current-line highlight across the whole width.
        let cursorRow = cursorVisualRow(cols: cols)
        if cursorRow >= scrollRow, cursorRow < scrollRow + visibleRows {
            let hy = textTop + CGFloat(cursorRow - scrollRow) * lineH
            surface.fill(CGRect(x: rect.minX, y: hy, width: rect.width, height: lineH),
                         color: .white.withAlpha(0.045))
        }

        surface.line(from: CGPoint(x: gutterRight, y: rect.minY),
                     to: CGPoint(x: gutterRight, y: statusTop), color: .windowBorder, width: 1)

        // Visible wrapped lines; continuation rows draw without a line number.
        var (lineIndex, chunk) = locate(visualRow: scrollRow, cols: cols)
        var y = textTop
        var row = 0
        while row < visibleRows, lineIndex < lines.count {
            let line = lines[lineIndex]
            let rowCount = visualRows(for: line, cols: cols)
            if chunk == 0 {
                let number = String(lineIndex + 1)
                let numberWidth = surface.textSize(number).width
                surface.text(number,
                             at: CGPoint(x: gutterRight - 6 - numberWidth, y: y),
                             color: lineIndex == cursorLine ? .gray : .darkGray)
            }
            let start = chunk * cols
            let end = min(line.count, start + cols)
            if start < end {
                surface.text(String(line[start..<end]),
                             at: CGPoint(x: textLeft, y: y),
                             color: .panelText)
            }
            chunk += 1
            if chunk >= rowCount { lineIndex += 1; chunk = 0 }
            row += 1
            y += lineH
        }

        // Blinking block cursor; the character under it is drawn inverted.
        if cursorRow >= scrollRow, cursorRow < scrollRow + visibleRows, blinkVisible {
            let (_, offset) = chunkAndOffset(col: cursorCol, line: lines[cursorLine], cols: cols)
            let cx = textLeft + CGFloat(offset) * charW
            let cy = textTop + CGFloat(cursorRow - scrollRow) * lineH
            surface.fill(CGRect(x: cx, y: cy, width: charW, height: lineH), color: .accent)
            if cursorCol < lines[cursorLine].count, offset < cols {
                surface.text(String(lines[cursorLine][cursorCol]),
                             at: CGPoint(x: cx, y: cy),
                             color: .windowBackground)
            }
        }

        // Thin vertical scrollbar when content overflows.
        if showScrollbar {
            let track = CGRect(x: rect.maxX - 7, y: rect.minY + 2, width: 4, height: editHeight - 4)
            surface.fill(track, color: .white.withAlpha(0.06))
            let thumbHeight = max(16, track.height * CGFloat(visibleRows) / CGFloat(max(1, totalRows)))
            let span = max(1, totalRows - visibleRows)
            let thumbY = track.minY + (track.height - thumbHeight) * CGFloat(scrollRow) / CGFloat(span)
            surface.fill(CGRect(x: track.minX, y: thumbY, width: track.width, height: thumbHeight),
                         color: .darkGray)
        }

        // Status bar: path left, cursor position centered, transient message right.
        surface.fill(CGRect(x: rect.minX, y: statusTop, width: rect.width, height: Self.statusBarHeight),
                     color: .black.withAlpha(0.22))
        surface.line(from: CGPoint(x: rect.minX, y: statusTop),
                     to: CGPoint(x: rect.maxX, y: statusTop), color: .windowBorder, width: 1)
        let textY = statusTop + (Self.statusBarHeight - lineH) / 2
        let pathText = fit(path ?? Self.nextUntitledPath(), maxWidth: rect.width * 0.42, surface: surface)
        surface.text(pathText, at: CGPoint(x: rect.minX + 8, y: textY), color: .gray)
        let position = "Ln \(cursorLine + 1), Col \(cursorCol + 1)"
        let positionWidth = surface.textSize(position).width
        surface.text(position, at: CGPoint(x: rect.midX - positionWidth / 2, y: textY), color: .gray)
        if let message {
            let shown = fit(message, maxWidth: rect.width * 0.3, surface: surface)
            let shownWidth = surface.textSize(shown).width
            surface.text(shown, at: CGPoint(x: rect.maxX - 8 - shownWidth, y: textY),
                         color: messageIsError ? .red : .green)
        }
    }

    /// Truncates a string (with an ASCII ellipsis) to fit a pixel width.
    private func fit(_ s: String, maxWidth: CGFloat, surface: Surface) -> String {
        if surface.textSize(s).width <= maxWidth { return s }
        var chars = Array(s)
        while chars.count > 1 {
            chars.removeLast()
            let candidate = String(chars) + "..."
            if surface.textSize(candidate).width <= maxWidth { return candidate }
        }
        return "..."
    }
}
