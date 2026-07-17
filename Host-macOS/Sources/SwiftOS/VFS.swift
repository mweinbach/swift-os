import Foundation
import CoreGraphics

/// A node in the in-memory filesystem tree, as exposed to the rest of the OS.
struct VNode {
    let name: String
    let isDirectory: Bool
    let size: Int
    let modified: Date
    let permissions: String // e.g. "drwxr-xr-x", "-rw-r--r--"
}

enum VFSError: Error, CustomStringConvertible {
    case notFound(path: String)
    case notDirectory(path: String)
    case isDirectory(path: String)
    case permissionDenied(path: String)
    case alreadyExists(path: String)
    case directoryNotEmpty(path: String)

    var description: String {
        switch self {
        case .notFound(let p): return "\(p): No such file or directory"
        case .notDirectory(let p): return "\(p): Not a directory"
        case .isDirectory(let p): return "\(p): Is a directory"
        case .permissionDenied(let p): return "\(p): Permission denied"
        case .alreadyExists(let p): return "\(p): File exists"
        case .directoryNotEmpty(let p): return "\(p): Directory not empty"
        }
    }
}

// MARK: - FSNode (private tree node)

/// Mutable tree node backing the VFS. Private to this file; the rest of the OS
/// only ever sees immutable `VNode` snapshots.
private final class FSNode {
    var name: String
    let isDirectory: Bool
    var contents: String            // regular files only
    var children: [String: FSNode]  // directories only
    var modified: Date
    let permissions: String

    init(name: String, isDirectory: Bool, contents: String = "",
         children: [String: FSNode] = [:], permissions: String) {
        self.name = name
        self.isDirectory = isDirectory
        self.contents = contents
        self.children = children
        self.modified = Date()
        self.permissions = permissions
    }

    static func dir(_ name: String, children: [FSNode] = []) -> FSNode {
        var table: [String: FSNode] = [:]
        for child in children { table[child.name] = child }
        return FSNode(name: name, isDirectory: true, children: table,
                      permissions: "drwxr-xr-x")
    }

    static func file(_ name: String, _ contents: String,
                     permissions: String = "-rw-r--r--") -> FSNode {
        FSNode(name: name, isDirectory: false, contents: contents,
               permissions: permissions)
    }

    /// A fake executable blob with a deterministic size in the ~14-40KB range,
    /// so `ls -l /bin` looks like a real system.
    static func executable(_ name: String) -> FSNode {
        var hash = 0
        for byte in name.utf8 { hash = (hash &* 31 &+ Int(byte)) & 0x3FFF_FFFF }
        let size = 14 * 1024 + hash % (26 * 1024)
        var blob = "\u{7F}ELF>swiftos:2.0:\(name)\n"
        let chunk = "01101000 01100101 01101100 01101100 01101111 00100000 01110111 01101111\n"
        while blob.utf8.count < size { blob += chunk }
        return FSNode(name: name, isDirectory: false,
                      contents: String(blob.prefix(size)),
                      permissions: "-rwxr-xr-x")
    }
}

// MARK: - VFS

final class VFS {
    static let shared = VFS()
    private init() {}

    /// Root of the tree, seeded lazily on first access.
    private lazy var root: FSNode = VFS.seedTree()

    // MARK: Query

    /// Lists the contents of the directory at `path` (absolute or relative-to-root).
    /// Directories sort first, then alphabetically. Throws notFound / notDirectory.
    func list(_ path: String) throws -> [VNode] {
        guard let node = resolve(path) else { throw VFSError.notFound(path: path) }
        guard node.isDirectory else { throw VFSError.notDirectory(path: path) }
        return node.children.values.map { vnode($0) }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let la = a.name.lowercased(), lb = b.name.lowercased()
            return la == lb ? a.name < b.name : la < lb
        }
    }

    /// Metadata for a single path. Throws notFound.
    func node(at path: String) throws -> VNode {
        guard let node = resolve(path) else { throw VFSError.notFound(path: path) }
        return vnode(node)
    }

    func exists(_ path: String) -> Bool { resolve(path) != nil }

    func isDirectory(_ path: String) -> Bool { resolve(path)?.isDirectory == true }

    // MARK: Contents

    /// Reads a regular file as UTF-8 text. Throws notFound / isDirectory.
    func read(_ path: String) throws -> String {
        guard let node = resolve(path) else { throw VFSError.notFound(path: path) }
        guard !node.isDirectory else { throw VFSError.isDirectory(path: path) }
        return node.contents
    }

    /// Writes (creating or replacing) a regular file. The parent directory must exist.
    func write(_ path: String, contents: String) throws {
        let full = VFS.normalize(path, cwd: "/")
        if let existing = resolve(full) {
            guard !existing.isDirectory else { throw VFSError.isDirectory(path: path) }
            existing.contents = contents
            existing.modified = Date()
            return
        }
        let base = VFS.basename(full)
        guard !base.isEmpty, base != "/" else { throw VFSError.isDirectory(path: path) }
        guard let parent = resolve(VFS.dirname(full)) else {
            throw VFSError.notFound(path: path)
        }
        guard parent.isDirectory else { throw VFSError.notDirectory(path: path) }
        parent.children[base] = FSNode.file(base, contents)
    }

    // MARK: Mutation

    /// Creates a single directory level. Throws alreadyExists / notFound (missing parent).
    func mkdir(_ path: String) throws {
        let full = VFS.normalize(path, cwd: "/")
        if resolve(full) != nil { throw VFSError.alreadyExists(path: path) }
        let base = VFS.basename(full)
        guard !base.isEmpty, base != "/" else { throw VFSError.alreadyExists(path: path) }
        guard let parent = resolve(VFS.dirname(full)) else {
            throw VFSError.notFound(path: path)
        }
        guard parent.isDirectory else { throw VFSError.notDirectory(path: path) }
        parent.children[base] = FSNode.dir(base)
    }

    /// Removes a file or an EMPTY directory. Throws notFound / directoryNotEmpty.
    func remove(_ path: String) throws {
        let full = VFS.normalize(path, cwd: "/")
        guard full != "/" else { throw VFSError.permissionDenied(path: path) }
        guard let target = resolve(full) else { throw VFSError.notFound(path: path) }
        if target.isDirectory && !target.children.isEmpty {
            throw VFSError.directoryNotEmpty(path: path)
        }
        resolve(VFS.dirname(full))?.children[VFS.basename(full)] = nil
    }

    // MARK: Path helpers (final implementations)

    /// Resolves `~`, relative paths (against `cwd`), `.` and `..` into a canonical
    /// absolute path. No symlink support.
    static func normalize(_ path: String, cwd: String) -> String {
        var p = path
        if p.hasPrefix("~") { p = "/home/user" + p.dropFirst() }
        if !p.hasPrefix("/") { p = cwd + "/" + p }
        var parts: [String] = []
        for comp in p.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." { _ = parts.popLast() } else { parts.append(String(comp)) }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func basename(_ path: String) -> String {
        let n = normalize(path, cwd: "/")
        return n == "/" ? "/" : String(n.split(separator: "/").last!)
    }

    static func dirname(_ path: String) -> String {
        let n = normalize(path, cwd: "/")
        let comps = n.split(separator: "/")
        guard comps.count > 1 else { return "/" }
        let joined = comps.dropLast().joined(separator: "/")
        return joined.isEmpty ? "/" : "/" + joined
    }

    // MARK: - Private

    private func resolve(_ path: String) -> FSNode? {
        let full = VFS.normalize(path, cwd: "/")
        if full == "/" { return root }
        var current = root
        for comp in full.split(separator: "/", omittingEmptySubsequences: true) {
            guard current.isDirectory, let next = current.children[String(comp)] else {
                return nil
            }
            current = next
        }
        return current
    }

    private func vnode(_ node: FSNode) -> VNode {
        VNode(name: node.name,
              isDirectory: node.isDirectory,
              size: node.isDirectory ? 4096 : node.contents.utf8.count,
              modified: node.modified,
              permissions: node.permissions)
    }

    // MARK: Seed

    private static func seedTree() -> FSNode {
        let binNames = [
            "swish", "sh", "bash", "ls", "cat", "echo", "pwd", "cd", "mkdir", "rm",
            "cp", "mv", "touch", "hostname", "uname", "date", "df", "ps", "grep",
            "head", "tail", "whoami", "env", "export", "history", "clear", "sudo",
            "open", "help", "exit",
        ]
        let usrBinNames = ["find", "which", "man", "uptime", "free", "neofetch", "wc"]

        let hostname = FSNode.file("hostname", "swiftos\n")

        let osRelease = FSNode.file("os-release", """
        NAME="SwiftOS"
        VERSION="1.0 (Agile Metal)"
        ID=swiftos
        ID_LIKE=darwin
        PRETTY_NAME="SwiftOS 1.0"
        VERSION_ID="1.0"
        HOME_URL="https://swiftos.dev/"
        SUPPORT_URL="https://swiftos.dev/support"
        BUG_REPORT_URL="https://swiftos.dev/bugs"
        """)

        let passwd = FSNode.file("passwd", """
        root:x:0:0:root:/root:/bin/swish
        daemon:x:1:1:daemon:/usr/sbin:/usr/bin/false
        user:x:1000:1000:SwiftOS User:/home/user:/bin/swish
        """)

        let fstab = FSNode.file("fstab", """
        # /etc/fstab: static file system information.
        #
        # <file system>  <mount point>  <type>    <options>          <dump>  <pass>
        /dev/disk1s1     /              swiftfs   rw,relatime          0       1
        tmpfs            /tmp           tmpfs     rw,nosuid,nodev      0       0
        """)

        let motd = FSNode.file("motd", """
        Welcome to SwiftOS 1.0 (kernel 6.9.4-swift)

         * Documentation:  /usr/share/doc
         * Support:        https://swiftos.dev/support
        """)

        let readme = FSNode.file("README.txt", """
        Welcome to SwiftOS!
        ===================

        This is your home directory. Everything in this system is a
        simulation written in Swift and rendered with Metal -- the
        filesystem, this file, and the terminal you are reading it in.

        Tips:
          * Run `neofetch` to see a summary of the system.
          * Run `ls /etc` to peek at the system configuration.
          * Run `open .` to browse this directory in the file manager.
          * Run `help` to list every command the shell understands.

        Have fun exploring!
        """)

        let notes = FSNode.file("notes.txt", """
        Shopping list
        - oat milk
        - coffee beans
        - USB-C cable

        Ideas
        - finish the SwiftOS renderer
        - teach grep about regular expressions someday
        - remember: a backup is just a cp -r you have not done yet
        """)

        let hello = FSNode.file("hello.swift", """
        import Foundation

        // A tiny program living inside a tiny OS.
        let greeting = "Hello from SwiftOS!"
        print(greeting)
        """)

        let syslog = FSNode.file("syslog", Kernel.shared.bootLog.joined(separator: "\n"))

        return FSNode.dir("/", children: [
            FSNode.dir("bin", children: binNames.map { FSNode.executable($0) }),
            FSNode.dir("etc", children: [hostname, osRelease, passwd, fstab, motd]),
            FSNode.dir("home", children: [
                FSNode.dir("user", children: [
                    readme,
                    notes,
                    FSNode.dir("projects", children: [hello]),
                ]),
            ]),
            FSNode.dir("root"),
            FSNode.dir("tmp"),
            FSNode.dir("usr", children: [
                FSNode.dir("bin", children: usrBinNames.map { FSNode.executable($0) }),
                FSNode.dir("share", children: [
                    FSNode.dir("doc"),
                ]),
            ]),
            FSNode.dir("var", children: [
                FSNode.dir("log", children: [syslog]),
            ]),
        ])
    }
}
