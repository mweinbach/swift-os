import Foundation
import CoreGraphics

/// STUB — the filesystem/shell subsystem replaces this with a real bash-like shell
/// ("swish"). Keep this API EXACTLY; TerminalApp compiles against it.
final class Shell {
    let fs: VFS
    var cwd: String
    var environment: [String: String]
    private(set) var history: [String] = []

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
    /// no trailing newline required). Plain text only — NO ANSI escape codes; the
    /// terminal colors the prompt and its own UI itself. Every executed line is
    /// appended to `history`.
    @discardableResult
    func execute(_ line: String) -> String {
        history.append(line)
        return "swish: shell not yet implemented\n"
    }
}
