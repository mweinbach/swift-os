// A Linux-style terminal emulator ("swift-term") hosting a `Shell`.
// Ported from Host-macOS/Sources/SwiftOS/Terminal.swift to Embedded Swift:
// no Foundation/AppKit, OSApp is a base CLASS (see WindowManager port).
// Immediate-mode: the model is a colored-run scrollback plus one editable
// input line; `draw` renders the current state, `tick` drives the cursor blink.
// Typing `top` switches the whole content area into a live htop-style process
// view (TOP mode, see the section below) until 'q'/Ctrl+C returns to the prompt.

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

    // MARK: TOP mode state

    /// When true, the content area shows a live htop-style process view
    /// instead of the scrollback + input line (entered by typing `top`).
    private var topMode = false
    /// Seconds between data refreshes in TOP mode (`top -d N` overrides).
    private var topRefreshInterval: TimeInterval = TerminalApp.defaultTopRefresh
    /// Time accumulated toward the next TOP-mode refresh.
    private var topRefreshElapsed: TimeInterval = 0
    /// Latest process snapshot, re-read from Platform.services at each refresh.
    private var topProcesses: [ProcessInfo] = []
    /// Latest per-core busy fractions (0...1), refreshed alongside topProcesses.
    private var topCoreLoads: [Double] = []
    /// Default TOP-mode refresh cadence: ~4 Hz.
    private static let defaultTopRefresh: TimeInterval = 0.25

    /// Commands offered for first-word Tab completion.
    private static let commandNames = [
        "cat", "cd", "clear", "cp", "date", "df", "echo", "env", "exit",
        "free", "grep", "head", "help", "history", "hostname", "kill", "ls",
        "mkdir", "mv", "nano", "ping", "ps", "pwd", "reboot", "rm", "rmdir",
        "shutdown", "smpdemo", "tail", "top", "touch", "tree", "udemo",
        "uname", "uptime", "whoami", "du",
    ]

    // MARK: OSApp

    public override init() {
        super.init()
        appendLine([(text: "SwiftOS 1.0 (kernel 1.0.0-aarch64)", color: .terminalText)])
        appendLine([(text: "Type 'help' to get started.", color: .gray)])
    }

    public override var title: String { "Terminal" }
    public override var preferredContentSize: CGSize { CGSize(width: 720, height: 440) }

    public override func tick(_ dt: TimeInterval) {
        blinkTime += dt
        // TOP mode: re-read the kernel's real task accounting on the refresh
        // cadence; the compositor draws the snapshot on its next frame.
        guard topMode else { return }
        topRefreshElapsed += dt
        if topRefreshElapsed >= topRefreshInterval {
            topRefreshElapsed = 0
            refreshTopProcesses()
        }
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

        // TOP mode replaces the whole content area (no scrollback, no prompt).
        if topMode {
            drawTopMode(surface, content: content, charWidth: charWidth,
                        lineHeight: lineHeight, columns: columns,
                        visibleRows: visibleRows)
            return
        }

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
        for line in TerminalApp.parseSGR(cleaned) { appendLine(line) }
    }

    // MARK: ANSI SGR parsing (command output only — the prompt stays manual)

    /// Palette for SGR 30-37 (black red green yellow blue magenta cyan white)
    /// mapped onto the app colors. Bright codes (90-97) and bold (1) derive
    /// from these via `brighten`.
    private static let sgrPalette: [Color] = [
        .darkGray, .red, .green, .yellow, .blue, .purple, .cyan, .lightGray,
    ]

    /// Bright variant of a color (SGR 1 / 90-97): mixed 45% toward white.
    private static func brighten(_ color: Color) -> Color {
        Color(color.r + (1 - color.r) * 0.45,
              color.g + (1 - color.g) * 0.45,
              color.b + (1 - color.b) * 0.45)
    }

    /// True for ASCII digits and ';' — written with scalar comparisons because
    /// the kernel's unicode data stubs make `Character.isNumber` return true
    /// for EVERY character (which let the CSI-param scan run to end-of-string).
    private static func isCSIParamChar(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return (v.value >= 48 && v.value <= 57) || v.value == 59 // '0'-'9' or ';'
    }

    /// Parses one command-output string into colored lines, understanding a
    /// small subset of ANSI: SGR sequences ESC [ <params> m — 0 reset, 1
    /// bright, 30-37 normal colors, 39 default foreground, 90-97 bright
    /// colors — are stripped and mapped to run colors; color state carries
    /// across lines of the same output. Other, malformed, or incomplete
    /// escape sequences are dropped gracefully: output can never crash or
    /// wedge the terminal.
    private static func parseSGR(_ text: String) -> [Line] {
        var lines: [Line] = []
        var runs: [Run] = []
        var pending = ""
        var base: Color = .terminalText
        var bright = false

        func flushPending() {
            guard !pending.isEmpty else { return }
            runs.append((text: pending, color: bright ? brighten(base) : base))
            pending = ""
        }
        func flushLine() {
            flushPending()
            lines.append(runs)
            runs = []
        }
        func applySGR(_ params: Substring) {
            for field in params.split(separator: ";", omittingEmptySubsequences: false) {
                let code = field.isEmpty ? 0 : (Int(field) ?? -1)
                switch code {
                case 0: base = .terminalText; bright = false
                case 1: bright = true
                case 30...37: base = sgrPalette[code - 30] // keeps the bright flag
                case 39: base = .terminalText
                case 90...97: base = brighten(sgrPalette[code - 90]); bright = false
                default: break // unsupported SGR (underline etc.): ignore
                }
            }
        }

        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\n" {
                flushLine()
                i = text.index(after: i)
                continue
            }
            if c != "\u{1B}" {
                pending.append(c)
                i = text.index(after: i)
                continue
            }
            // Escape sequence: only CSI (ESC [ params <final>) is understood.
            var j = text.index(after: i)
            guard j < text.endIndex else { break } // trailing ESC: drop
            guard text[j] == "[" else {
                // Two-byte escape (ESC + one char): drop both, keep going.
                i = text.index(after: j)
                continue
            }
            j = text.index(after: j)
            let paramsStart = j
            while j < text.endIndex, TerminalApp.isCSIParamChar(text[j]) {
                j = text.index(after: j)
            }
            guard j < text.endIndex else { break } // incomplete CSI: drop the rest
            let params = text[paramsStart..<j]
            let final = text[j]
            i = text.index(after: j)
            guard final == "m" else { continue } // other CSI (cursor moves): strip
            flushPending()
            applySGR(params)
        }
        flushPending()
        if !runs.isEmpty { lines.append(runs) }
        return lines
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
            // TOP mode has no scrollback: the wheel is ignored.
            guard !topMode else { return }
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
        // TOP mode: scrollback input/history/completion are all suspended;
        // only 'q' / Ctrl+C are meaningful (they leave TOP mode).
        if topMode {
            handleTopKey(key)
            return
        }

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
        } else if let refresh = TerminalApp.parseTopInvocation(trimmed) {
            // Intercepted BEFORE the shell (like clear/exit): this shadows the
            // shell's own `top` command — intended; the terminal's TOP mode is
            // the interactive process viewer now.
            enterTopMode(refreshInterval: refresh)
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

    // MARK: TOP mode (interactive fullscreen process view)

    /// If `trimmed` is exactly `top` or `top -d <seconds>`, returns the TOP-mode
    /// refresh interval in seconds (clamped to 0.1...60); any other line
    /// returns nil and falls through to the shell.
    private static func parseTopInvocation(_ trimmed: String) -> TimeInterval? {
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.first == "top" else { return nil }
        if parts.count == 1 { return defaultTopRefresh }
        guard parts.count == 3, parts[1] == "-d",
              let seconds = parseDecimal(parts[2]), seconds > 0 else { return nil }
        return min(60, max(0.1, seconds))
    }

    /// Parses a positive decimal ("2", "0.5") with scalar-range checks —
    /// `Character.isNumber` returns true for EVERY character on-device (the
    /// unicode data stubs; see isCSIParamChar), so it can't be used here.
    private static func parseDecimal(_ s: Substring) -> Double? {
        var value = 0.0
        var fracScale = 0.1
        var seenDigit = false
        var seenDot = false
        for scalar in s.unicodeScalars {
            if scalar.value == 46 { // '.'
                if seenDot { return nil }
                seenDot = true
            } else if scalar.value >= 48, scalar.value <= 57 { // '0'-'9'
                seenDigit = true
                let digit = Double(scalar.value - 48)
                if seenDot {
                    value += digit * fracScale
                    fracScale /= 10
                } else {
                    value = value * 10 + digit
                }
            } else {
                return nil
            }
        }
        return seenDigit ? value : nil
    }

    private func enterTopMode(refreshInterval: TimeInterval) {
        topMode = true
        topRefreshInterval = refreshInterval
        topRefreshElapsed = 0
        refreshTopProcesses() // the first TOP frame already has data
    }

    private func exitTopMode() {
        topMode = false
        topProcesses = []
        topCoreLoads = []
        scrollToBottom() // scrollback was never touched: prompt view restored
        resetBlink()
    }

    /// Re-reads the real kernel task accounting, sorted htop-style by %CPU
    /// descending (ties by PID ascending so the row order doesn't jitter).
    /// Also refreshes the per-core busy fractions (KernelServices.perCoreLoad,
    /// already smoothed; falls back to one synthetic core from the process
    /// table's total %CPU when the scheduler reports no per-core data).
    private func refreshTopProcesses() {
        topProcesses = Platform.services.processes.sorted {
            $0.cpuPercent != $1.cpuPercent
                ? $0.cpuPercent > $1.cpuPercent
                : $0.pid < $1.pid
        }
        let loads = Platform.services.perCoreLoad
        if !loads.isEmpty {
            topCoreLoads = loads
        } else {
            let processCPU = topProcesses.reduce(0) { $0 + $1.cpuPercent }
            topCoreLoads = [min(1, processCPU / 100)]
        }
    }

    /// Keys in TOP mode: 'q' / Ctrl+C exits; everything else is ignored.
    private func handleTopKey(_ key: KeyEvent) {
        let mods = key.modifiers
        if mods.contains(.control) {
            if key.keyCode == 8 || key.characters == "\u{3}" { exitTopMode() } // Ctrl+C
            return
        }
        if !mods.contains(.command),
           key.characters == "q" || key.characters == "Q" {
            exitTopMode()
        }
    }

    /// htop-style load colors, same thresholds as System Monitor:
    /// green < 5%, yellow < 15%, red above.
    private static func topPercentColor(_ value: Double) -> Color {
        if value < 5 { return .green }
        if value < 15 { return .yellow }
        return .red
    }

    /// The live htop-style view. The layout is recomputed from the content
    /// rect (in character cells) on every frame, so resizing reflows it.
    /// Rows: header, CPU summary, MEM bar, column header, process rows
    /// (fitted to the remaining visible rows), optional footer hint.
    private func drawTopMode(_ surface: Surface, content: CGRect,
                             charWidth: CGFloat, lineHeight: CGFloat,
                             columns: Int, visibleRows: Int) {
        let services = Platform.services!

        var rows: [[Run]] = []

        // Header: hostname, ticking uptime, load average.
        let (l1, l5, l15) = services.loadAverage
        rows.append([
            (text: services.hostname, color: .green),
            (text: "  up ", color: .darkGray),
            (text: TimeFmt.uptime(services.uptime), color: .terminalText),
            (text: "   load average: ", color: .darkGray),
            (text: NumFmt.f2(l1) + " " + NumFmt.f2(l5) + " " + NumFmt.f2(l15),
             color: .green),
        ])

        // CPU summary: '#'/'-' block bar + total % + task counts.
        let totalCPU = min(100, topProcesses.reduce(0) { $0 + $1.cpuPercent })
        let running = topProcesses.filter { $0.state == "R" }.count
        rows.append(topBarRow(label: "CPU",
                              fraction: totalCPU / 100,
                              fillColor: .green,
                              text: NumFmt.f1(totalCPU) + "%",
                              textColor: TerminalApp.topPercentColor(totalCPU),
                              suffix: "  tasks " + String(topProcesses.count)
                                  + ", running " + String(running),
                              columns: columns))

        // Per-core mini-line: "cpu0 97% cpu1 88% cpu2 3% cpu3 0%".
        var coreRow: [Run] = []
        for (index, load) in topCoreLoads.enumerated() {
            let percent = Int(load * 100 + 0.5)
            if !coreRow.isEmpty { coreRow.append((text: " ", color: .darkGray)) }
            coreRow.append((text: "cpu\(index) ", color: .darkGray))
            coreRow.append((text: "\(percent)%",
                            color: TerminalApp.topPercentColor(Double(percent))))
        }
        if !coreRow.isEmpty { rows.append(coreRow) }

        // MEM bar: '#' used / '-' free, orange like System Monitor.
        let usedMB = services.usedMemoryMB
        let totalMB = services.totalMemoryMB
        rows.append(topBarRow(label: "MEM",
                              fraction: totalMB > 0 ? usedMB / totalMB : 0,
                              fillColor: .orange,
                              text: String(Int(usedMB)) + "/" + String(Int(totalMB)) + "MB",
                              textColor: .terminalText,
                              suffix: "",
                              columns: columns))

        // Column header: PID NAME %CPU MEM STAT (numeric fields right-aligned).
        let pidW = 5, cpuW = 5, memW = 6, statW = 4
        let nameW = max(4, columns - pidW - cpuW - memW - statW - 4)
        rows.append([(text: NumFmt.right("PID", pidW) + " "
                        + NumFmt.left("NAME", nameW) + " "
                        + NumFmt.right("%CPU", cpuW) + " "
                        + NumFmt.right("MEM", memW) + " "
                        + NumFmt.left("STAT", statW),
                      color: .gray)])

        // Process rows, dense (one line each), fitted to the visible rows.
        let hasFooter = visibleRows >= 8
        let capacity = max(0, visibleRows - rows.count - (hasFooter ? 1 : 0))
        for p in topProcesses.prefix(capacity) {
            rows.append([
                (text: NumFmt.right(String(p.pid), pidW), color: .gray),
                (text: " " + NumFmt.left(p.name, nameW), color: .terminalText),
                (text: " " + NumFmt.right(NumFmt.f1(p.cpuPercent), cpuW),
                 color: TerminalApp.topPercentColor(p.cpuPercent)),
                (text: " " + NumFmt.right(String(Int(p.memoryMB)), memW),
                 color: .terminalText),
                (text: " " + NumFmt.left(p.state, statW),
                 color: p.state == "R" ? .green : .darkGray),
            ])
        }

        // Draw top-down, truncating every row at the visible column count.
        var y = content.minY
        for row in rows {
            var x = content.minX
            for run in TerminalApp.truncateRuns(row, toWidth: columns) {
                surface.text(run.text, at: CGPoint(x: x, y: y), color: run.color)
                x += charWidth * CGFloat(run.text.count)
            }
            y += lineHeight
        }

        // Footer hint pinned to the bottom row when there is room.
        if hasFooter {
            surface.text("q quit   refresh " + NumFmt.f1(topRefreshInterval) + "s",
                         at: CGPoint(x: content.minX, y: content.maxY - lineHeight),
                         color: .darkGray)
        }
    }

    /// One "LBL[###----] text suffix" bar row; the bar takes the column slack.
    private func topBarRow(label: String, fraction: Double, fillColor: Color,
                           text: String, textColor: Color,
                           suffix: String, columns: Int) -> [Run] {
        // Layout: LBL "[" bar "] " text suffix.
        let barWidth = max(2, columns - label.count - 4 - text.count - suffix.count)
        let clamped = min(1, max(0, fraction))
        let filled = min(barWidth, Int(clamped * Double(barWidth) + 0.5))
        return [
            (text: label, color: .gray),
            (text: "[", color: .darkGray),
            (text: String(repeating: "#", count: filled), color: fillColor),
            (text: String(repeating: "-", count: barWidth - filled), color: .darkGray),
            (text: "] ", color: .darkGray),
            (text: text, color: textColor),
            (text: suffix, color: .darkGray),
        ]
    }

    /// Truncates a run list to at most `columns` characters, preserving colors.
    private static func truncateRuns(_ runs: [Run], toWidth columns: Int) -> [Run] {
        var out: [Run] = []
        var remaining = columns
        for run in runs {
            if remaining <= 0 { break }
            if run.text.count <= remaining {
                out.append(run)
                remaining -= run.text.count
            } else {
                out.append((text: String(run.text.prefix(remaining)), color: run.color))
                remaining = 0
            }
        }
        return out
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
