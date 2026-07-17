// A Linux-style terminal emulator ("swift-term") hosting a `Shell`.
// Ported from Host-macOS/Sources/SwiftOS/Terminal.swift to Embedded Swift:
// no Foundation/AppKit, OSApp is a base CLASS (see WindowManager port).
// Immediate-mode: the model is a colored-run scrollback plus one editable
// input line; `draw` renders the current state, `tick` drives the cursor blink.

public final class TerminalApp: OSApp {
    /// One colored text fragment within a line.
    private typealias Run = (text: String, color: Color)
    /// A logical line: a sequence of colored runs.
    private typealias Line = [Run]

    // MARK: Model

    private let shell = Shell()
    private var scrollback: [Line] = []
    private let scrollbackLimit = 1000

    /// Editable input buffer; the cursor sits BEFORE the character at `cursorIndex`.
    private var input = ""
    private var cursorIndex = 0 // in Characters
    private var historyIndex: Int?
    private var stashedInput = ""

    /// Rows scrolled up from the bottom (0 = pinned to the live edge).
    private var scrollOffset = 0
    private var scrollPixelRemainder: CGFloat = 0
    private var blinkTime: TimeInterval = 0

    // Geometry cached from the last draw, used to map scroll/key events.
    private var contentRect: CGRect = .zero
    private var lastLineHeight: CGFloat = 16
    private var lastVisibleRows = 1
    private var lastMaxScroll = 0

    // Wrapped-scrollback cache, rebuilt when the scrollback or column count changes.
    private var wrappedScrollback: [[Run]]?
    private var wrappedColumns = -1

    /// Commands offered for first-word Tab completion.
    private static let commandNames = [
        "cat", "cd", "clear", "cp", "date", "df", "echo", "env", "exit",
        "free", "grep", "head", "help", "history", "hostname", "kill", "ls",
        "mkdir", "mv", "ps", "pwd", "rm", "rmdir", "tail", "touch", "uname",
        "uptime", "whoami",
    ]

    // MARK: OSApp

    public override init() {
        appendLine([(text: "SwiftOS 1.0 (kernel 6.9.4-swift)", color: .terminalText)])
        appendLine([(text: "Type 'help' to get started.", color: .gray)])
    }

    public override var title: String { "Terminal" }
    public override var preferredContentSize: CGSize { CGSize(width: 720, height: 440) }

    public override func tick(_ dt: TimeInterval) {
        blinkTime += dt
    }

    // MARK: Draw

    public override func draw(_ surface: Surface, in rect: CGRect) {
        contentRect = rect
        surface.fill(rect, color: .terminalBackground)

        let metrics = surface.textSize("M")
        let charWidth = max(metrics.width, 1)
        let lineHeight = max(metrics.height, 1)
        lastLineHeight = lineHeight

        let pad: CGFloat = 8
        let content = CGRect(x: rect.minX + pad, y: rect.minY + pad,
                             width: max(0, rect.width - pad * 2),
                             height: max(0, rect.height - pad * 2))
        let columns = max(1, Int(content.width / charWidth))
        let visibleRows = max(1, Int(content.height / lineHeight))
        lastVisibleRows = visibleRows

        // Rebuild the wrapped scrollback cache when stale.
        if wrappedColumns != columns {
            wrappedScrollback = nil
            wrappedColumns = columns
        }
        if wrappedScrollback == nil {
            wrappedScrollback = scrollback.flatMap { wrapLine($0, columns: columns) }
        }
        let sRows = wrappedScrollback!

        // Wrap the input line (prompt runs + buffer) and locate the cursor.
        let pRuns = promptRuns()
        let promptLength = pRuns.reduce(0) { $0 + $1.text.count }
        var inputRows = wrapLine(pRuns + [(text: input, color: .terminalText)], columns: columns)
        let cursorRowInInput = (promptLength + cursorIndex) / columns
        let cursorCol = (promptLength + cursorIndex) % columns
        if cursorIndex == input.count && cursorRowInInput >= inputRows.count {
            inputRows.append([]) // cursor wraps past an exactly-full line
        }

        let totalRows = sRows.count + inputRows.count
        let maxScroll = max(0, totalRows - visibleRows)
        lastMaxScroll = maxScroll
        scrollOffset = min(scrollOffset, maxScroll)

        let endIndex = totalRows - scrollOffset
        let startIndex = max(0, endIndex - visibleRows)

        // Bottom-anchored: the last visible row sits flush at the content bottom.
        var y = content.maxY - lineHeight * CGFloat(endIndex - startIndex)
        var rowIndex = startIndex
        while rowIndex < endIndex {
            let row = rowIndex < sRows.count ? sRows[rowIndex] : inputRows[rowIndex - sRows.count]
            var x = content.minX
            for run in row {
                surface.text(run.text, at: CGPoint(x: x, y: y), color: run.color)
                x += charWidth * CGFloat(run.text.count)
            }
            y += lineHeight
            rowIndex += 1
        }

        // Block cursor, blinking with a ~0.53s on/off phase.
        let blinkOn = blinkTime.truncatingRemainder(dividingBy: 1.06) < 0.53
        if blinkOn && scrollOffset == 0 {
            let cursorRow = sRows.count + cursorRowInInput
            if cursorRow >= startIndex && cursorRow < endIndex {
                let cy = content.maxY - lineHeight * CGFloat(endIndex - cursorRow)
                let cx = content.minX + charWidth * CGFloat(cursorCol)
                surface.fill(CGRect(x: cx, y: cy, width: charWidth, height: lineHeight),
                             color: .accent)
                if cursorIndex < input.count {
                    let ch = input[input.index(input.startIndex, offsetBy: cursorIndex)]
                    surface.text(String(ch), at: CGPoint(x: cx, y: cy), color: .terminalBackground)
                }
            }
        }

        // Thin scrollbar on the right edge whenever there is scrollback.
        if maxScroll > 0 {
            let track = CGRect(x: rect.maxX - 5, y: content.minY, width: 3, height: content.height)
            let thumbHeight = max(16, track.height * CGFloat(visibleRows) / CGFloat(totalRows))
            let fraction = CGFloat(scrollOffset) / CGFloat(maxScroll)
            let thumbY = track.maxY - thumbHeight - fraction * (track.height - thumbHeight)
            surface.fill(CGRect(x: track.minX, y: thumbY, width: track.width, height: thumbHeight),
                         color: scrollOffset > 0 ? .gray : .darkGray)
        }
    }

    /// Splits a logical line into display rows of at most `columns` characters,
    /// preserving run colors. An empty line yields one empty row.
    private func wrapLine(_ line: Line, columns: Int) -> [[Run]] {
        var rows: [[Run]] = []
        var current: [Run] = []
        var col = 0
        for run in line {
            var remaining = Substring(run.text)
            while !remaining.isEmpty {
                if col == columns {
                    rows.append(current)
                    current = []
                    col = 0
                }
                let take = min(columns - col, remaining.count)
                current.append((text: String(remaining.prefix(take)), color: run.color))
                remaining = remaining.dropFirst(take)
                col += take
            }
        }
        if !current.isEmpty || rows.isEmpty {
            rows.append(current)
        }
        return rows
    }

    /// Colored runs for the shell prompt: "user@host" green, path blue.
    private func promptRuns() -> [Run] {
        let prompt = shell.promptString
        guard let colon = prompt.firstIndex(of: ":") else {
            return [(text: prompt, color: .green)]
        }
        let userHost = String(prompt[..<colon])
        var path = String(prompt[prompt.index(after: colon)...])
        var suffix = ""
        if path.hasSuffix("$ ") {
            suffix = "$ "
            path = String(path.dropLast(2))
        }
        return [
            (text: userHost, color: .green),
            (text: ":", color: .terminalText),
            (text: path, color: .blue),
            (text: suffix, color: .terminalText),
        ]
    }

    // MARK: Scrollback mutation

    private func appendLine(_ line: Line) {
        scrollback.append(line)
        if scrollback.count > scrollbackLimit {
            scrollback.removeFirst(scrollback.count - scrollbackLimit)
        }
        wrappedScrollback = nil
        scrollToBottom() // new output jumps to the bottom
    }

    private func appendOutput(_ output: String) {
        guard !output.isEmpty else { return }
        // Foundation's replacingOccurrences(of: "\r", with: "") inlined.
        var cleaned = ""
        for ch in output where ch != "\r" { cleaned.append(ch) }
        var parts = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if parts.last == "" { parts.removeLast() } // trailing newline terminates, no extra blank
        for part in parts {
            appendLine([(text: part, color: .terminalText)])
        }
    }

    private func clearScrollback() {
        scrollback.removeAll()
        wrappedScrollback = nil
        scrollToBottom()
    }

    private func scrollToBottom() {
        scrollOffset = 0
        scrollPixelRemainder = 0
    }

    private func resetBlink() {
        blinkTime = 0
    }

    // MARK: Events

    public override func handle(_ event: OSEvent) {
        switch event {
        case .keyDown(let key):
            handleKey(key)
        case .scrollWheel(_, _, let deltaY):
            scrollPixelRemainder += deltaY
            let rows = Int(scrollPixelRemainder / lastLineHeight)
            if rows != 0 {
                scrollPixelRemainder -= CGFloat(rows) * lastLineHeight
                scrollOffset = max(0, min(lastMaxScroll, scrollOffset + rows))
            }
        default:
            break
        }
    }

    private func handleKey(_ key: KeyEvent) {
        let mods = key.modifiers

        if mods.contains(.command) {
            // Cmd+V paste from the host clipboard (NSPasteboard) was DELETED in
            // the kernel port: there is no AppKit/NSPasteboard on bare metal.
            // Command chords are swallowed so they never insert stray text.
            return
        }
        if mods.contains(.control) {
            if key.keyCode == 8 || key.characters == "\u{3}" { interruptInput() } // Ctrl+C
            else if key.keyCode == 37 || key.characters == "\u{c}" { clearScrollback() } // Ctrl+L
            return
        }

        switch key.keyCode {
        case 36, 76: commitInput()                 // Return / keypad Enter
        case 51: backspace()                       // Backspace
        case 117: forwardDelete()                  // Forward-Delete
        case 123: moveCursor(by: -1)               // Left
        case 124: moveCursor(by: 1)                // Right
        case 125: historyUp()                      // Up
        case 126: historyDown()                    // Down
        case 115: setCursor(0)                     // Home
        case 119: setCursor(input.count)           // End
        case 53:                                   // Escape: abandon the input
            input = ""
            cursorIndex = 0
            historyIndex = nil
            afterEdit()
        case 48: completeWord()                    // Tab
        case 116: scrollOffset = min(lastMaxScroll, scrollOffset + lastVisibleRows) // PageUp
        case 121: scrollOffset = max(0, scrollOffset - lastVisibleRows)             // PageDown
        default:
            let chars = key.characters
            if !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
                insert(chars)
            }
        }
    }

    // MARK: Editing

    private func afterEdit() {
        historyIndex = nil
        scrollToBottom()
        resetBlink()
    }

    private func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let idx = input.index(input.startIndex, offsetBy: cursorIndex)
        input.insert(contentsOf: text, at: idx)
        cursorIndex += text.count
        afterEdit()
    }

    private func backspace() {
        guard cursorIndex > 0 else { return }
        input.remove(at: input.index(input.startIndex, offsetBy: cursorIndex - 1))
        cursorIndex -= 1
        afterEdit()
    }

    private func forwardDelete() {
        guard cursorIndex < input.count else { return }
        input.remove(at: input.index(input.startIndex, offsetBy: cursorIndex))
        afterEdit()
    }

    private func moveCursor(by delta: Int) {
        setCursor(cursorIndex + delta)
    }

    private func setCursor(_ index: Int) {
        cursorIndex = max(0, min(input.count, index))
        scrollToBottom()
        resetBlink()
    }

    /// Return: echo prompt + input into the scrollback, then run the line.
    private func commitInput() {
        let line = input
        appendLine(promptRuns() + [(text: line, color: .terminalText)])
        input = ""
        cursorIndex = 0
        historyIndex = nil
        stashedInput = ""
        resetBlink()

        let trimmed = TerminalApp.trimWhitespace(line)
        if trimmed == "clear" {
            clearScrollback()
        } else if trimmed == "exit" {
            WindowManager.shared.closeApp(self)
        } else if !trimmed.isEmpty {
            appendOutput(shell.execute(line))
        }
    }

    /// Ctrl+C: echo the line with a trailing ^C and abandon it.
    private func interruptInput() {
        appendLine(promptRuns() + [(text: input, color: .terminalText),
                                   (text: "^C", color: .terminalText)])
        input = ""
        cursorIndex = 0
        historyIndex = nil
        resetBlink()
    }

    // MARK: History

    private func historyUp() {
        guard !shell.history.isEmpty else { return }
        if let index = historyIndex {
            historyIndex = max(0, index - 1)
        } else {
            stashedInput = input
            historyIndex = shell.history.count - 1
        }
        input = shell.history[historyIndex!]
        cursorIndex = input.count
        scrollToBottom()
        resetBlink()
    }

    private func historyDown() {
        guard let index = historyIndex else { return }
        if index + 1 < shell.history.count {
            historyIndex = index + 1
            input = shell.history[index + 1]
        } else {
            historyIndex = nil
            input = stashedInput
        }
        cursorIndex = input.count
        scrollToBottom()
        resetBlink()
    }

    // MARK: Tab completion

    private func completeWord() {
        let upToCursor = String(input.prefix(cursorIndex))
        let wordStart = upToCursor.lastIndex(of: " ")
            .map { upToCursor.index(after: $0) } ?? upToCursor.startIndex
        let word = String(upToCursor[wordStart...])
        // Foundation's .whitespaces is space + tab.
        let isFirstWord = upToCursor[..<wordStart].allSatisfy { $0 == " " || $0 == "\t" }

        var candidates: [String] = []
        if isFirstWord && !word.contains("/") {
            candidates += TerminalApp.commandNames.filter { $0.hasPrefix(word) }
        }

        // File completion: split the word into a directory part and a name prefix.
        let slash = word.lastIndex(of: "/")
        let dirPart = slash.map { String(word[...$0]) } ?? ""
        let prefix = slash.map { String(word[word.index(after: $0)...]) } ?? word
        let dirPath = VFS.normalize(dirPart.isEmpty ? "." : dirPart, cwd: shell.cwd)
        if let nodes = try? shell.fs.list(dirPath) {
            for node in nodes where node.name.hasPrefix(prefix) {
                candidates.append(dirPart + node.name + (node.isDirectory ? "/" : ""))
            }
        }

        let unique = Array(Set(candidates)).sorted()
        guard let first = unique.first else { return }
        if unique.count == 1 {
            var completion = first
            if !completion.hasSuffix("/") { completion += " " }
            replaceCurrentWord(with: completion, wordLength: word.count)
            return
        }
        // Ambiguous: extend only to the longest common prefix.
        var common = first
        for candidate in unique.dropFirst() {
            common = TerminalApp.commonPrefix(common, candidate)
        }
        if common.count > word.count {
            replaceCurrentWord(with: common, wordLength: word.count)
        }
    }

    private func replaceCurrentWord(with completion: String, wordLength: Int) {
        let start = input.index(input.startIndex, offsetBy: cursorIndex - wordLength)
        let end = input.index(input.startIndex, offsetBy: cursorIndex)
        input.replaceSubrange(start..<end, with: completion)
        cursorIndex = cursorIndex - wordLength + completion.count
        afterEdit()
    }

    // MARK: String helpers (Foundation replacements)

    /// `trimmingCharacters(in: .whitespacesAndNewlines)` replacement:
    /// strips spaces, tabs, CRs and newlines from both ends.
    private static func trimWhitespace(_ s: String) -> String {
        func isTrim(_ c: Character) -> Bool {
            c == " " || c == "\t" || c == "\n" || c == "\r"
        }
        var start = s.startIndex
        var end = s.endIndex
        while start < end, isTrim(s[start]) { start = s.index(after: start) }
        while end > start {
            let prev = s.index(before: end)
            if !isTrim(s[prev]) { break }
            end = prev
        }
        return String(s[start..<end])
    }

    private static func commonPrefix(_ a: String, _ b: String) -> String {
        var result = ""
        for (ca, cb) in zip(a, b) {
            if ca != cb { break }
            result.append(ca)
        }
        return result
    }
}
