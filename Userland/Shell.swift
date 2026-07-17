// "swish" — a small bash-like shell for SwiftOS (Embedded Swift port).
// No Foundation: dates come from TimeFmt/Platform.services, numbers from
// NumFmt. All VFS errors are the typed VFSError.

/// "swish" — a small bash-like shell for SwiftOS. Parses one line at a time:
/// quote-aware tokenizing, `;` command separators, a `|` pipeline stage, and
/// `>` / `>>` redirection into the VFS. Command output may carry ANSI SGR
/// color (ls/grep/errors); the terminal strips and renders it (parseSGR).
final class Shell {
    let fs: VFS
    var cwd: String
    var environment: [String: String]
    private(set) var history: [String] = []

    /// False while a command's output is NOT going straight to the terminal —
    /// a non-final pipeline stage or a `>`/`>>` redirection. SGR color is then
    /// suppressed so escape bytes never corrupt downstream commands or files.
    private var colorEnabled = true

    init(fs: VFS = .shared) {
        self.fs = fs
        self.environment = [
            "USER": "user",
            "HOME": "/home/user",
            "PATH": "/bin:/usr/bin",
            "SHELL": "/bin/swish",
            "TERM": "swift-term",
            "HOSTNAME": "swiftos",
            "PWD": "/home/user",
            "LANG": "en_US.UTF-8",
        ]
        self.cwd = self.environment["HOME"]!
    }

    /// bash-style prompt, e.g. "user@swiftos:~$ " (home replaced with ~).
    var promptString: String {
        let home = environment["HOME"] ?? "/home/user"
        var dir = cwd
        if dir == home { dir = "~" }
        else if dir.hasPrefix(home + "/") { dir = "~" + dir.dropFirst(home.count) }
        let user = environment["USER"] ?? "user"
        let host = environment["HOSTNAME"] ?? "swiftos"
        return "\(user)@\(host):\(dir)$ "
    }

    /// Executes one command line and returns its full output (may be multiple lines,
    /// no trailing newline). Output may contain ANSI SGR color sequences (see
    /// `colorEnabled`); the terminal renders them, while the prompt itself is
    /// colored by the terminal. Every executed line is appended to `history`.
    @discardableResult
    func execute(_ line: String) -> String {
        history.append(line)
        environment["PWD"] = cwd

        let tokens = tokenize(line)
        var commands: [[Token]] = [[]]
        for token in tokens {
            if case .semicolon = token { commands.append([]) }
            else { commands[commands.count - 1].append(token) }
        }

        var outputs: [String] = []
        for command in commands where !command.isEmpty {
            let out = runPipeline(command)
            if !out.isEmpty { outputs.append(out) }
        }
        var result = outputs.joined(separator: "\n")
        while result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    // MARK: - Tokenizing

    /// Words keep their quoting structure so that `~` / `$VAR` expansion can be
    /// deferred until execution time — after earlier commands on the same line
    /// have run, matching bash semantics.
    private enum Token {
        case word([Segment])
        case semicolon
        case pipe
        case redirect(append: Bool)
    }

    private enum Quoting { case unquoted, doubleQuoted, singleQuoted }

    private struct Segment {
        let text: String
        let quoting: Quoting
    }

    /// Marker prefix for backslash-escaped characters; protects them from
    /// `$` / `~` expansion at execution time.
    private static let escapeMarker: Character = "\u{1}"

    /// Splits a raw line into tokens. Handles single quotes (fully literal),
    /// double quotes (expansions deferred), backslash escapes, and the
    /// unquoted separators `;`, `|`, `>`, `>>`.
    private func tokenize(_ line: String) -> [Token] {
        var tokens: [Token] = []
        var segments: [Segment] = []
        var buffer = ""
        var bufferQuoting: Quoting = .unquoted
        var wordStarted = false
        var inSingle = false
        var inDouble = false

        func flushBuffer() {
            if !buffer.isEmpty {
                segments.append(Segment(text: buffer, quoting: bufferQuoting))
                buffer = ""
            }
        }
        func flushWord() {
            flushBuffer()
            if wordStarted { tokens.append(.word(segments)) }
            segments = []
            wordStarted = false
        }

        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]

            if inSingle {
                if c == "'" {
                    flushBuffer()
                    inSingle = false
                    bufferQuoting = .unquoted
                } else {
                    buffer.append(c)
                }
                i = line.index(after: i)
                continue
            }

            if inDouble {
                switch c {
                case "\"":
                    flushBuffer()
                    inDouble = false
                    bufferQuoting = .unquoted
                    i = line.index(after: i)
                case "\\":
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "\"" || line[next] == "\\" || line[next] == "$" {
                        buffer.append(Shell.escapeMarker)
                        buffer.append(line[next])
                        i = line.index(after: next)
                    } else {
                        buffer.append(c)
                        i = line.index(after: i)
                    }
                default:
                    buffer.append(c)
                    i = line.index(after: i)
                }
                continue
            }

            switch c {
            case " ", "\t":
                flushWord()
                i = line.index(after: i)
            case "'":
                flushBuffer()
                bufferQuoting = .singleQuoted
                inSingle = true
                wordStarted = true
                i = line.index(after: i)
            case "\"":
                flushBuffer()
                bufferQuoting = .doubleQuoted
                inDouble = true
                wordStarted = true
                i = line.index(after: i)
            case ";":
                flushWord()
                tokens.append(.semicolon)
                i = line.index(after: i)
            case "|":
                flushWord()
                tokens.append(.pipe)
                i = line.index(after: i)
            case ">":
                flushWord()
                let next = line.index(after: i)
                if next < line.endIndex, line[next] == ">" {
                    tokens.append(.redirect(append: true))
                    i = line.index(after: next)
                } else {
                    tokens.append(.redirect(append: false))
                    i = next
                }
            case "\\":
                let next = line.index(after: i)
                if next < line.endIndex {
                    buffer.append(Shell.escapeMarker)
                    buffer.append(line[next])
                    wordStarted = true
                    i = line.index(after: next)
                } else {
                    i = next
                }
            default:
                buffer.append(c)
                wordStarted = true
                i = line.index(after: i)
            }
        }
        flushWord()
        return tokens
    }

    /// Expands one word into its final string at execution time: `~` at word
    /// start (unquoted) and `$VAR` / `${VAR}` everywhere except single quotes.
    private func expandWord(_ segments: [Segment]) -> String {
        var result = ""
        for (index, segment) in segments.enumerated() {
            switch segment.quoting {
            case .singleQuoted:
                result += resolveEscapes(segment.text)
            case .doubleQuoted:
                result += expandVariables(in: segment.text)
            case .unquoted:
                var text = segment.text
                if index == 0, text.hasPrefix("~") {
                    text = (environment["HOME"] ?? "/home/user") + text.dropFirst()
                }
                result += expandVariables(in: text)
            }
        }
        return result
    }

    private func resolveEscapes(_ text: String) -> String {
        guard text.contains(Shell.escapeMarker) else { return text }
        var result = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == Shell.escapeMarker {
                let next = text.index(after: i)
                if next < text.endIndex {
                    result.append(text[next])
                    i = text.index(after: next)
                } else {
                    i = next
                }
            } else {
                result.append(text[i])
                i = text.index(after: i)
            }
        }
        return result
    }

    /// ASCII [A-Za-z0-9_] test via scalar values — the kernel's unicode data
    /// stubs make `Character.isLetter`/`isNumber` return true for EVERY
    /// character, which would let a $VAR name scan run to end-of-string.
    private func isVarNameChar(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return (v.value >= 48 && v.value <= 57)      // 0-9
            || (v.value >= 65 && v.value <= 90)      // A-Z
            || (v.value >= 97 && v.value <= 122)     // a-z
            || v.value == 95                         // _
    }

    /// Expands `$VAR` and `${VAR}` from the environment; escape-marked
    /// characters are emitted literally.
    private func expandVariables(in text: String) -> String {
        var result = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == Shell.escapeMarker {
                let next = text.index(after: i)
                if next < text.endIndex {
                    result.append(text[next])
                    i = text.index(after: next)
                } else {
                    i = next
                }
                continue
            }
            if c == "$" {
                var j = text.index(after: i)
                guard j < text.endIndex else { result.append("$"); i = j; continue }
                if text[j] == "{" {
                    if let close = text[j...].firstIndex(of: "}") {
                        let name = String(text[text.index(after: j)..<close])
                        result.append(environment[name] ?? "")
                        i = text.index(after: close)
                    } else {
                        result.append("$")
                        i = j
                    }
                    continue
                }
                var name = ""
                while j < text.endIndex, isVarNameChar(text[j]) {
                    name.append(text[j])
                    j = text.index(after: j)
                }
                if name.isEmpty { result.append("$") } else { result.append(environment[name] ?? "") }
                i = j
                continue
            }
            result.append(c)
            i = text.index(after: i)
        }
        return result
    }

    // MARK: - Pipeline execution

    private func runPipeline(_ tokens: [Token]) -> String {
        var stages: [[Token]] = [[]]
        for token in tokens {
            if case .pipe = token { stages.append([]) }
            else { stages[stages.count - 1].append(token) }
        }
        var input: String? = nil
        var output = ""
        for (index, stage) in stages.enumerated() {
            // Only the final stage writes to the terminal — earlier stages
            // feed the next command, where SGR bytes would corrupt parsing.
            colorEnabled = index == stages.count - 1
            output = runSimple(stage, stdin: input)
            input = output.isEmpty ? nil : output
        }
        colorEnabled = true
        return output
    }

    /// Runs one simple command (words + optional redirection). `stdin` is the
    /// output of the previous pipeline stage, if any.
    private func runSimple(_ stage: [Token], stdin: String?) -> String {
        var words: [String] = []
        var redirect: (path: String, append: Bool)? = nil
        var i = 0
        while i < stage.count {
            switch stage[i] {
            case .word(let segments):
                words.append(expandWord(segments))
            case .redirect(let append):
                if i + 1 < stage.count, case .word(let segments) = stage[i + 1] {
                    redirect = (expandWord(segments), append)
                    i += 1
                } else {
                    return sgrError("swish: syntax error near unexpected token `>'")
                }
            case .semicolon, .pipe:
                break
            }
            i += 1
        }

        guard let command = words.first, !command.isEmpty else {
            // e.g. a bare `> file` just truncates/creates the file.
            if let r = redirect {
                do { try fs.write(VFS.normalize(r.path, cwd: cwd), contents: "") }
                catch { return sgrError("swish: \(vfsErrorMessage(r.path, error))") }
            }
            return ""
        }

        if redirect != nil { colorEnabled = false } // colors never leak into files
        let output = dispatch(command, args: Array(words.dropFirst()), stdin: stdin)

        if let r = redirect {
            var text = output
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            let full = VFS.normalize(r.path, cwd: cwd)
            if r.append { text = ((try? fs.read(full)) ?? "") + text }
            do { try fs.write(full, contents: text) }
            catch { return sgrError("swish: \(vfsErrorMessage(r.path, error))") }
            return ""
        }
        return output
    }

    // MARK: - ANSI SGR output (rendered by TerminalApp.parseSGR)

    /// Wraps an error message in red — suppressed when piped or redirected.
    private func sgrError(_ message: String) -> String {
        guard colorEnabled else { return message }
        return "\u{1B}[31m" + message + "\u{1B}[0m"
    }

    /// A file name colored ls-style: directories bright blue, files with an
    /// executable permission bit green (both suppressed when piped/redirected).
    private func colorizedName(_ node: VNode) -> String {
        guard colorEnabled else { return node.name }
        if node.permissions.hasPrefix("d") {
            return "\u{1B}[1;34m" + node.name + "\u{1B}[0m"
        }
        if node.permissions.contains("x") {
            return "\u{1B}[32m" + node.name + "\u{1B}[0m"
        }
        return node.name
    }

    // MARK: - Command dispatch

    private func dispatch(_ command: String, args: [String], stdin: String?) -> String {
        switch command {
        case "help": return helpText
        case "ls": return cmdLS(args)
        case "cd": return cmdCD(args)
        case "pwd": return cwd
        case "cat": return cmdCat(args, stdin: stdin)
        case "echo": return cmdEcho(args)
        case "touch": return cmdTouch(args)
        case "mkdir": return cmdMkdir(args)
        case "rm": return cmdRM(args)
        case "cp": return cmdCP(args)
        case "mv": return cmdMV(args)
        case "head": return cmdHeadTail(args, stdin: stdin, isHead: true)
        case "tail": return cmdHeadTail(args, stdin: stdin, isHead: false)
        case "grep": return cmdGrep(args, stdin: stdin)
        case "wc": return cmdWC(args, stdin: stdin)
        case "find": return cmdFind(args)
        case "uname":
            if args.contains("-a") {
                return "SwiftOS \(Platform.services.hostname) \(Platform.services.kernelRelease) #1 SMP \(Platform.services.machine)"
            }
            return "SwiftOS"
        case "whoami": return environment["USER"] ?? "user"
        case "hostname": return Platform.services.hostname
        case "ps": return cmdPS()
        case "uptime": return cmdUptime()
        case "date": return TimeFmt.fullDate(Platform.services.wallClockMs)
        case "df": return cmdDF(args)
        case "free": return cmdFree(args)
        case "env":
            return environment.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        case "export": return cmdExport(args)
        case "history":
            return history.enumerated()
                .map { pad(String($0.offset + 1), to: 5) + "  " + $0.element }
                .joined(separator: "\n")
        case "which": return cmdWhich(args)
        case "man": return cmdMan(args)
        case "neofetch": return cmdNeofetch()
        case "kill": return cmdKill(args)
        case "nano": return cmdNano(args)
        case "top": return cmdTop(args)
        case "sudo":
            return "user is not in the sudoers file. This incident will be reported."
        case "open": return cmdOpen(args)
        case "exit", "clear": return ""
        default:
            return sgrError("swish: \(command): command not found")
        }
    }

    // MARK: - Commands

    private func cmdLS(_ args: [String]) -> String {
        var long = false, all = false
        var path: String? = nil
        for arg in args {
            if arg.hasPrefix("-"), arg.count > 1 {
                for flag in arg.dropFirst() {
                    switch flag {
                    case "l": long = true
                    case "a": all = true
                    default: return sgrError("ls: invalid option -- '\(flag)'")
                    }
                }
            } else if path == nil {
                path = arg
            }
        }
        let target = path ?? "."
        let full = VFS.normalize(target, cwd: cwd)

        if fs.isDirectory(full) {
            var nodes: [VNode]
            do { nodes = try fs.list(full) }
            catch { return sgrError("ls: \(vfsErrorMessage(target, error))") }
            if !all { nodes = nodes.filter { !$0.name.hasPrefix(".") } }
            if long {
                return nodes.map { longFormat($0) }.joined(separator: "\n")
            }
            return columnize(nodes)
        }
        do {
            let node = try fs.node(at: full)
            return long ? longFormat(node) : colorizedName(node)
        } catch {
            return sgrError("ls: \(vfsErrorMessage(target, error))")
        }
    }

    private func cmdCD(_ args: [String]) -> String {
        let target = args.first ?? environment["HOME"] ?? "/home/user"
        let full = VFS.normalize(target, cwd: cwd)
        guard fs.exists(full) else { return sgrError("cd: \(target): No such file or directory") }
        guard fs.isDirectory(full) else { return sgrError("cd: \(target): Not a directory") }
        environment["OLDPWD"] = cwd
        cwd = full
        environment["PWD"] = full
        return ""
    }

    private func cmdCat(_ args: [String], stdin: String?) -> String {
        if args.isEmpty { return stdin ?? "" }
        var result = ""
        for file in args {
            do {
                result += try fs.read(VFS.normalize(file, cwd: cwd))
            } catch {
                if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
                result += sgrError("cat: \(vfsErrorMessage(file, error))") + "\n"
            }
        }
        return result
    }

    private func cmdEcho(_ args: [String]) -> String {
        var words = args
        while words.first == "-n" { words.removeFirst() }
        return words.joined(separator: " ")
    }

    private func cmdTouch(_ args: [String]) -> String {
        if args.isEmpty { return sgrError("touch: missing file operand") }
        var errors: [String] = []
        for file in args {
            let full = VFS.normalize(file, cwd: cwd)
            do { try fs.write(full, contents: (try? fs.read(full)) ?? "") }
            catch { errors.append(sgrError("touch: \(vfsErrorMessage(file, error))")) }
        }
        return errors.joined(separator: "\n")
    }

    private func cmdMkdir(_ args: [String]) -> String {
        if args.isEmpty { return sgrError("mkdir: missing operand") }
        var errors: [String] = []
        for dir in args {
            do { try fs.mkdir(VFS.normalize(dir, cwd: cwd)) }
            catch { errors.append(sgrError("mkdir: \(vfsErrorMessage(dir, error))")) }
        }
        return errors.joined(separator: "\n")
    }

    private func cmdRM(_ args: [String]) -> String {
        var recursive = false, force = false
        var targets: [String] = []
        for arg in args {
            if arg.hasPrefix("-"), arg.count > 1 {
                for flag in arg.dropFirst() {
                    switch flag {
                    case "r", "R": recursive = true
                    case "f": force = true
                    default: return sgrError("rm: invalid option -- '\(flag)'")
                    }
                }
            } else {
                targets.append(arg)
            }
        }
        if targets.isEmpty { return sgrError("rm: missing operand") }
        var errors: [String] = []
        for target in targets {
            let full = VFS.normalize(target, cwd: cwd)
            guard fs.exists(full) else {
                if !force { errors.append(sgrError("rm: \(target): No such file or directory")) }
                continue
            }
            if fs.isDirectory(full), !recursive {
                errors.append(sgrError("rm: \(target): Is a directory"))
                continue
            }
            do { try removeTree(full) }
            catch { errors.append(sgrError("rm: \(vfsErrorMessage(target, error))")) }
        }
        return errors.joined(separator: "\n")
    }

    private func cmdCP(_ args: [String]) -> String {
        var recursive = false
        var operands: [String] = []
        for arg in args {
            if arg.hasPrefix("-"), arg.count > 1 {
                for flag in arg.dropFirst() {
                    if flag == "r" || flag == "R" { recursive = true }
                    else { return sgrError("cp: invalid option -- '\(flag)'") }
                }
            } else {
                operands.append(arg)
            }
        }
        if operands.isEmpty { return sgrError("cp: missing file operand") }
        if operands.count == 1 {
            return sgrError("cp: missing destination file operand after '\(operands[0])'")
        }
        let source = VFS.normalize(operands[0], cwd: cwd)
        var dest = VFS.normalize(operands[1], cwd: cwd)
        guard fs.exists(source) else {
            return sgrError("cp: \(operands[0]): No such file or directory")
        }
        if fs.isDirectory(source), !recursive {
            return sgrError("cp: \(operands[0]): Is a directory")
        }
        if fs.isDirectory(dest) { dest += "/" + VFS.basename(source) }
        do { try copyTree(source, dest) }
        catch { return sgrError("cp: \(vfsErrorMessage(operands[1], error))") }
        return ""
    }

    private func cmdMV(_ args: [String]) -> String {
        let operands = args.filter { !$0.hasPrefix("-") }
        if operands.isEmpty { return sgrError("mv: missing file operand") }
        if operands.count == 1 {
            return sgrError("mv: missing destination file operand after '\(operands[0])'")
        }
        let source = VFS.normalize(operands[0], cwd: cwd)
        var dest = VFS.normalize(operands[1], cwd: cwd)
        guard fs.exists(source) else {
            return sgrError("mv: \(operands[0]): No such file or directory")
        }
        if fs.isDirectory(dest) { dest += "/" + VFS.basename(source) }
        do {
            try copyTree(source, dest)
            try removeTree(source)
        } catch {
            return sgrError("mv: \(vfsErrorMessage(operands[1], error))")
        }
        return ""
    }

    private func cmdHeadTail(_ args: [String], stdin: String?, isHead: Bool) -> String {
        let name = isHead ? "head" : "tail"
        var count = 10
        var file: String? = nil
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "-n", i + 1 < args.count {
                count = Int(args[i + 1]) ?? 10
                i += 2
            } else if arg.hasPrefix("-n"), let value = Int(arg.dropFirst(2)) {
                count = value
                i += 1
            } else if arg.hasPrefix("-"), let value = Int(arg.dropFirst()) {
                count = value
                i += 1
            } else {
                file = arg
                i += 1
            }
        }
        let text: String
        if let file {
            do { text = try fs.read(VFS.normalize(file, cwd: cwd)) }
            catch { return sgrError("\(name): \(vfsErrorMessage(file, error))") }
        } else if let stdin {
            text = stdin
        } else {
            return ""
        }
        let lines = logicalLines(text)
        let slice = isHead ? Array(lines.prefix(count)) : Array(lines.suffix(count))
        return slice.joined(separator: "\n")
    }

    private func cmdGrep(_ args: [String], stdin: String?) -> String {
        guard let pattern = args.first else { return sgrError("usage: grep <pattern> [file]") }
        let text: String?
        if args.count > 1 {
            do { text = try fs.read(VFS.normalize(args[1], cwd: cwd)) }
            catch { return sgrError("grep: \(vfsErrorMessage(args[1], error))") }
        } else {
            text = stdin
        }
        guard let text else { return "" }
        // Plain substring match only — no regex engine in the kernel.
        let matches = logicalLines(text).filter { containsSubstring($0, pattern) }
        // Highlight only when this output goes straight to the terminal; a
        // downstream pipe or file would receive the raw escape bytes.
        guard colorEnabled else { return matches.joined(separator: "\n") }
        return matches.map { highlight($0, pattern: pattern) }.joined(separator: "\n")
    }

    /// Bold-red SGR around every occurrence of `pattern` in `line`.
    private func highlight(_ line: String, pattern: String) -> String {
        if pattern.isEmpty { return line }
        var result = ""
        var i = line.startIndex
        while i < line.endIndex {
            if line[i...].hasPrefix(pattern) {
                result += "\u{1B}[1;31m" + pattern + "\u{1B}[0m"
                i = line.index(i, offsetBy: pattern.count)
            } else {
                result.append(line[i])
                i = line.index(after: i)
            }
        }
        return result
    }

    /// Stdlib-only substring test (Foundation's `String.contains(_: String)`
    /// does not exist in the kernel). Empty pattern matches everything.
    private func containsSubstring(_ text: String, _ pattern: String) -> Bool {
        if pattern.isEmpty { return true }
        var i = text.startIndex
        while i < text.endIndex {
            if text[i...].hasPrefix(pattern) { return true }
            i = text.index(after: i)
        }
        return false
    }

    private func cmdWC(_ args: [String], stdin: String?) -> String {
        var linesOnly = false
        var file: String? = nil
        for arg in args {
            if arg == "-l" { linesOnly = true }
            else if arg.hasPrefix("-") { return sgrError("wc: invalid option -- '\(arg.dropFirst().first ?? " ")'") }
            else { file = arg }
        }
        let text: String
        var label = ""
        if let file {
            do { text = try fs.read(VFS.normalize(file, cwd: cwd)) }
            catch { return sgrError("wc: \(vfsErrorMessage(file, error))") }
            label = " " + file
        } else if let stdin {
            text = stdin
        } else {
            return ""
        }
        let lines = logicalLines(text).count
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        let bytes = text.utf8.count
        if linesOnly { return "\(lines)\(label)" }
        return pad(String(lines), to: 7) + " " + pad(String(words), to: 7) + " "
            + pad(String(bytes), to: 7) + label
    }

    private func cmdFind(_ args: [String]) -> String {
        let base = args.first ?? "."
        let full = VFS.normalize(base, cwd: cwd)
        guard fs.exists(full) else { return sgrError("find: \(base): No such file or directory") }
        var results: [String] = []
        func walk(_ display: String, _ absolute: String) {
            results.append(display)
            guard fs.isDirectory(absolute), let children = try? fs.list(absolute) else { return }
            for child in children {
                let childDisplay = display == "/" ? "/" + child.name : display + "/" + child.name
                let childAbsolute = absolute == "/" ? "/" + child.name : absolute + "/" + child.name
                walk(childDisplay, childAbsolute)
            }
        }
        let display = base.hasSuffix("/") && base.count > 1 ? String(base.dropLast()) : base
        walk(display, full)
        return results.joined(separator: "\n")
    }

    private func cmdPS() -> String {
        var lines = ["  PID NAME                      %CPU      MEM STAT"]
        for process in Platform.services.processes {
            let pid = pad(String(process.pid), to: 5)
            let name = padLeft(process.name, to: 22)
            let cpu = pad(NumFmt.f1(process.cpuPercent), to: 6)
            let mem = pad(NumFmt.f1(process.memoryMB), to: 8)
            lines.append("\(pid) \(name) \(cpu) \(mem) \(process.state)")
        }
        return lines.joined(separator: "\n")
    }

    private func cmdUptime() -> String {
        let up = Platform.services.uptime
        let (one, five, fifteen) = Platform.services.loadAverage
        return " \(Shell.wallClockTime()) up \(TimeFmt.uptime(up)), 1 user, load average: "
            + "\(NumFmt.f2(one)), \(NumFmt.f2(five)), \(NumFmt.f2(fifteen))"
    }

    private func cmdDF(_ args: [String]) -> String {
        if args.contains("-h") {
            return """
            Filesystem      Size  Used Avail Use% Mounted on
            /dev/disk1s1    256G   19G  224G   8% /
            tmpfs           4.0G     0  4.0G   0% /tmp
            """
        }
        return """
        Filesystem     1K-blocks     Used Available Use% Mounted on
        /dev/disk1s1   268435456 19922944 234881024   8% /
        tmpfs            4194304        0   4194304   0% /tmp
        """
    }

    private func cmdFree(_ args: [String]) -> String {
        let total = Platform.services.totalMemoryMB
        let used = Platform.services.usedMemoryMB
        let freeMB = total - used
        let shared = 44.0
        let cached = 512.0
        let available = min(total, freeMB + cached)

        func row(_ label: String, _ values: [String]) -> String {
            var line = padLeft(label, to: 12)
            for value in values { line += pad(value, to: 12) }
            return line
        }
        let header = row("", ["total", "used", "free", "shared", "buff/cache", "available"])

        if args.contains("-h") {
            let mem = row("Mem:", [human(total), human(used), human(freeMB),
                                   human(shared), human(cached), human(available)])
            let swap = row("Swap:", [human(0), human(0), human(0)])
            return header + "\n" + mem + "\n" + swap
        }
        let mem = row("Mem:", [Int(total * 1024), Int(used * 1024), Int(freeMB * 1024),
                               Int(shared * 1024), Int(cached * 1024), Int(available * 1024)]
            .map { String($0) })
        let swap = row("Swap:", ["0", "0", "0"])
        return header + "\n" + mem + "\n" + swap
    }

    private func cmdExport(_ args: [String]) -> String {
        if args.isEmpty {
            return environment.keys.sorted()
                .map { "declare -x \($0)=\"\(environment[$0] ?? "")\"" }
                .joined(separator: "\n")
        }
        for arg in args {
            if let equal = arg.firstIndex(of: "=") {
                let key = String(arg[arg.startIndex..<equal])
                let value = String(arg[arg.index(after: equal)...])
                if !key.isEmpty { environment[key] = value }
            } else if environment[arg] == nil {
                environment[arg] = ""
            }
        }
        return ""
    }

    private func cmdWhich(_ args: [String]) -> String {
        if args.isEmpty { return "" }
        let pathDirs = (environment["PATH"] ?? "/bin:/usr/bin").split(separator: ":")
        var found: [String] = []
        for command in args {
            for dir in pathDirs {
                let candidate = String(dir) + "/" + command
                if fs.exists(candidate), !fs.isDirectory(candidate) {
                    found.append(candidate)
                    break
                }
            }
        }
        return found.joined(separator: "\n")
    }

    private func cmdMan(_ args: [String]) -> String {
        guard let topic = args.first else { return "What manual page do you want?" }
        if let page = Shell.manPages[topic] { return page }
        return sgrError("No manual entry for \(topic)")
    }

    private func cmdNeofetch() -> String {
        let services: KernelServices = Platform.services
        let user = environment["USER"] ?? "user"
        let host = environment["HOSTNAME"] ?? "swiftos"
        let info: [String] = [
            "\(user)@\(host)",
            String(repeating: "-", count: user.count + host.count + 1),
            "OS: SwiftOS 1.0 arm64",
            "Host: Metal GPU",
            "Kernel: \(services.kernelRelease)",
            "Uptime: \(friendlyUptime(services.uptime))",
            "Shell: \(services.shellName)",
            "WM: \(services.wmName)",
            "Terminal: \(services.terminalName)",
            "CPU: Apple Silicon",
            "Memory: \(Int(services.usedMemoryMB))MiB / \(Int(services.totalMemoryMB))MiB",
        ]
        let logo = Shell.neofetchLogo
        let logoWidth = logo.map { $0.count }.max() ?? 0
        let rows = max(logo.count, info.count)
        var lines: [String] = []
        for index in 0..<rows {
            let left = index < logo.count
                ? padLeft(logo[index], to: logoWidth)
                : String(repeating: " ", count: logoWidth)
            let right = index < info.count ? info[index] : ""
            lines.append(right.isEmpty ? left : left + "  " + right)
        }
        return lines.joined(separator: "\n")
    }

    private func cmdOpen(_ args: [String]) -> String {
        guard let target = args.first else { return sgrError("usage: open <path>") }
        let full = VFS.normalize(target, cwd: cwd)
        guard fs.exists(full) else { return sgrError("open: \(target): No such file or directory") }
        if fs.isDirectory(full) {
            WindowManager.shared.open(app: FileManagerApp(path: full))
        } else {
            WindowManager.shared.open(app: TextEditorApp(path: full))
        }
        return "Opening \(full)"
    }

    /// `kill <pid>` — closes the window whose process owns that PID (window
    /// processes are the only user-space processes that really exist here).
    private func cmdKill(_ args: [String]) -> String {
        guard let arg = args.first, let pid = Int(arg) else {
            return sgrError("usage: kill <pid>")
        }
        if let window = WindowManager.shared.windows.first(where: { $0.processPID == pid }) {
            WindowManager.shared.close(window)
            return "killed \(pid)"
        }
        return sgrError("kill: \(pid): Operation not permitted")
    }

    /// `nano <file>` — the Text Editor stands in for nano; like the real nano
    /// it happily opens files that do not exist yet (created on save).
    private func cmdNano(_ args: [String]) -> String {
        guard let file = args.first else { return sgrError("usage: nano <file>") }
        WindowManager.shared.open(app: TextEditorApp(path: VFS.normalize(file, cwd: cwd)))
        return "Opening \(file)"
    }

    /// `top` — the System Monitor is the interactive process viewer.
    private func cmdTop(_ args: [String]) -> String {
        WindowManager.shared.open(app: SystemMonitorApp())
        return "System Monitor opened (q quits processes there)"
    }

    // MARK: - Recursive helpers

    private func copyTree(_ source: String, _ dest: String) throws(VFSError) {
        if fs.isDirectory(source) {
            if !fs.exists(dest) {
                try fs.mkdir(dest)
            } else if !fs.isDirectory(dest) {
                throw VFSError.alreadyExists(path: dest)
            }
            for child in try fs.list(source) {
                try copyTree(source + "/" + child.name, dest + "/" + child.name)
            }
        } else {
            try fs.write(dest, contents: (try? fs.read(source)) ?? "")
        }
    }

    private func removeTree(_ path: String) throws(VFSError) {
        if fs.isDirectory(path) {
            for child in try fs.list(path) {
                try removeTree(path + "/" + child.name)
            }
        }
        try fs.remove(path)
    }

    // MARK: - Formatting helpers

    private func pad(_ s: String, to width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }

    private func padLeft(_ s: String, to width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    private static func twoDigit(_ v: Int) -> String {
        v < 10 ? "0\(v)" : "\(v)"
    }

    /// "HH:mm:ss" of the current wall clock (was a DateFormatter in the host app).
    private static func wallClockTime() -> String {
        let d = CivilDate(epochMs: Platform.services.wallClockMs)
        return "\(twoDigit(d.hour)):\(twoDigit(d.minute)):\(twoDigit(d.second))"
    }

    private func logicalLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private func longFormat(_ node: VNode) -> String {
        pad(node.permissions, to: 11) + pad(String(node.size), to: 7) + " "
            + TimeFmt.fileDate(node.modified) + " " + colorizedName(node)
    }

    /// Column layout uses the VISIBLE name widths; SGR bytes are added around
    /// each padded cell so alignment survives the color codes.
    private func columnize(_ nodes: [VNode]) -> String {
        if nodes.isEmpty { return "" }
        let columnWidth = (nodes.map { $0.name.count }.max() ?? 0) + 2
        let columns = max(1, 80 / max(1, columnWidth))
        let rows = (nodes.count + columns - 1) / columns
        var lines: [String] = []
        for row in 0..<rows {
            var line = ""
            for column in 0..<columns {
                let index = column * rows + row
                guard index < nodes.count else { continue }
                let node = nodes[index]
                line += colorizedName(node)
                if column != columns - 1 {
                    line += String(repeating: " ", count: max(0, columnWidth - node.name.count))
                }
            }
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func friendlyUptime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if days == 0 { parts.append("\(minutes) min\(minutes == 1 ? "" : "s")") }
        return parts.isEmpty ? "0 mins" : parts.joined(separator: ", ")
    }

    private func human(_ megabytes: Double) -> String {
        if megabytes >= 1024 { return NumFmt.f1(megabytes / 1024) + "G" }
        if megabytes >= 1 { return NumFmt.fixed(megabytes, 0) + "M" }
        return "0"
    }

    /// Formats a VFS error bash-style, but with the path the user actually typed.
    private func vfsErrorMessage(_ argument: String, _ error: VFSError) -> String {
        switch error {
        case .notFound: return "\(argument): No such file or directory"
        case .notDirectory: return "\(argument): Not a directory"
        case .isDirectory: return "\(argument): Is a directory"
        case .permissionDenied: return "\(argument): Permission denied"
        case .alreadyExists: return "\(argument): File exists"
        case .directoryNotEmpty: return "\(argument): Directory not empty"
        }
    }

    // MARK: - Static text

    private var helpText: String {
        """
        SwiftOS swish, version 5.2 -- available commands:

          help                   show this help
          ls [-l] [-a] [path]    list directory contents
          cd [dir]               change directory (default: $HOME)
          pwd                    print working directory
          cat <file>...          print file contents
          echo [-n] [text]       print text
          touch <file>...        create a file or update its timestamp
          mkdir <dir>...         create directories
          rm [-r] [-f] <path>... remove files or directories
          cp [-r] <src> <dst>    copy files or directories
          mv <src> <dst>         move or rename
          head [-n N] [file]     print the first N lines (default 10)
          tail [-n N] [file]     print the last N lines (default 10)
          grep <pat> [file]      print lines containing a substring
          wc [-l] [file]         count lines, words and bytes
          find [path]            list files recursively
          uname [-a]             system information
          whoami                 print the current user
          hostname               print the system hostname
          ps [aux]               print the process table
          kill <pid>             close the app window owning a process
          top                    open the System Monitor (process viewer)
          uptime                 uptime and load average
          date                   current date and time
          df [-h]                disk usage
          free [-h]              memory usage
          env                    print environment variables
          export K=V             set an environment variable
          history                print command history
          which <cmd>            locate a command in $PATH
          man <cmd>              read a manual page
          neofetch               system summary with logo
          open <path>            open a file or folder in a GUI app
          nano <file>            edit a file in the Text Editor
          sudo <cmd>             attempt privilege escalation
          clear                  clear the screen
          exit                   close the terminal

        Pipelines: cmd1 | cmd2    Redirection: cmd > file, cmd >> file
        Separator: cmd1 ; cmd2    Quotes: 'literal'  "expands $VARS"
        """
    }

    private static let neofetchLogo: [String] = [
        "         /\\        ",
        "        /  \\       ",
        "       / /\\ \\      ",
        "      / /  \\ \\     ",
        "     / / /\\ \\ \\    ",
        "    / / /  \\ \\ \\   ",
        "   / / /    \\ \\ \\  ",
        "  / / /      \\ \\ \\ ",
        " / /_/        \\ \\_\\",
        " \\____\\        \\___\\",
    ]

    private static let manPages: [String: String] = [
        "ls": """
        ls(1) - list directory contents
        usage: ls [-l] [-a] [path]
          -l  long format (permissions, size, mtime)   -a  include dotfiles
        """,
        "cd": """
        cd(1) - change the working directory
        usage: cd [dir]
        With no argument, changes to $HOME. Understands ~, . and ..
        """,
        "pwd": """
        pwd(1) - print the current working directory
        usage: pwd
        """,
        "cat": """
        cat(1) - concatenate files and print them
        usage: cat <file>...
        With no files, reads standard input (useful in a pipeline).
        """,
        "echo": """
        echo(1) - print a line of text
        usage: echo [-n] [text...]
          -n  do not print the trailing newline
        """,
        "grep": """
        grep(1) - print lines containing a substring
        usage: grep <pattern> [file]
        With no file, filters standard input, e.g. `cat f | grep foo`.
        """,
        "rm": """
        rm(1) - remove files or directories
        usage: rm [-r] [-f] <path>...
          -r  remove directories recursively   -f  ignore missing files
        """,
        "cp": """
        cp(1) - copy files or directories
        usage: cp [-r] <source> <destination>
        Copying a directory requires -r.
        """,
        "mv": """
        mv(1) - move or rename files and directories
        usage: mv <source> <destination>
        If destination is a directory, the source is moved inside it.
        """,
        "mkdir": """
        mkdir(1) - create directories
        usage: mkdir <dir>...
        Creates one level at a time; the parent must exist.
        """,
        "touch": """
        touch(1) - create files or update timestamps
        usage: touch <file>...
        """,
        "find": """
        find(1) - list files recursively
        usage: find [path]
        Prints every path below the starting point, one per line.
        """,
        "wc": """
        wc(1) - count lines, words and bytes
        usage: wc [-l] [file]
          -l  print only the line count
        """,
        "head": """
        head(1) - print the first lines of a file
        usage: head [-n N] [file]
        Reads standard input when no file is given. See also: tail(1).
        """,
        "tail": """
        tail(1) - print the last lines of a file
        usage: tail [-n N] [file]
        Reads standard input when no file is given. See also: head(1).
        """,
        "man": """
        man(1) - an interface to the system reference manuals
        usage: man <command>
        Try `man ls`, `man grep` or `man neofetch`.
        """,
        "neofetch": """
        neofetch(1) - display system information next to a fancy logo
        usage: neofetch
        """,
        "kill": """
        kill(1) - terminate a process
        usage: kill <pid>
        Closes the window that owns the process (see `ps` for PIDs). Only
        window-backed processes can be killed; anything else is not permitted.
        """,
        "nano": """
        nano(1) - edit a file
        usage: nano <file>
        Opens the file in the Text Editor. A missing file starts empty and is
        created when you save (Ctrl+S there).
        """,
        "top": """
        top(1) - display and manage running processes
        usage: top
        Opens the System Monitor; select a process there and press q to quit it.
        """,
    ]
}
