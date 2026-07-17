// In-memory filesystem tree for SwiftOS userland (Embedded Swift port).
// No Foundation: timestamps are UInt64 wall-clock milliseconds taken from
// Platform.services.wallClockMs at seed/mutation time (format with
// TimeFmt.fileDate). All throws are TYPED: throws(VFSError).

/// A node in the in-memory filesystem tree, as exposed to the rest of the OS.
struct VNode {
    let name: String
    let isDirectory: Bool
    let size: Int
    let modified: UInt64 // wall-clock ms since epoch
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
    var modified: UInt64            // wall-clock ms
    let permissions: String
    /// SwiftFS inode backing this node, or -1 when it is RAM-only (no disk,
    /// or the never-persisted /var/log/syslog).
    var inode: Int = -1

    init(name: String, isDirectory: Bool, contents: String = "",
         children: [String: FSNode] = [:], permissions: String) {
        self.name = name
        self.isDirectory = isDirectory
        self.contents = contents
        self.children = children
        self.modified = Platform.services.wallClockMs
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

    /// Root of the tree. Lazily realized on first access: if a SwiftFS disk
    /// is present it is mounted (or formatted + seeded) first — see `Disk` —
    /// otherwise the tree comes from `seedTree()` exactly as before.
    private var rootStorage: FSNode?
    private var root: FSNode {
        if let r = rootStorage { return r }
        Disk.initAndMount()          // idempotent; may set rootStorage itself
        if let r = rootStorage { return r }
        let r = VFS.seedTree()
        rootStorage = r
        return r
    }

    // MARK: Query

    /// Lists the contents of the directory at `path` (absolute or relative-to-root).
    /// Directories sort first, then alphabetically. Throws notFound / notDirectory.
    func list(_ path: String) throws(VFSError) -> [VNode] {
        guard let node = resolve(path) else { throw VFSError.notFound(path: path) }
        guard node.isDirectory else { throw VFSError.notDirectory(path: path) }
        return node.children.values.map { vnode($0) }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let la = a.name.lowercased(), lb = b.name.lowercased()
            return la == lb ? a.name < b.name : la < lb
        }
    }

    /// Metadata for a single path. Throws notFound.
    func node(at path: String) throws(VFSError) -> VNode {
        guard let node = resolve(path) else { throw VFSError.notFound(path: path) }
        return vnode(node)
    }

    func exists(_ path: String) -> Bool { resolve(path) != nil }

    func isDirectory(_ path: String) -> Bool { resolve(path)?.isDirectory == true }

    // MARK: Contents

    /// Reads a regular file as UTF-8 text. Throws notFound / isDirectory.
    func read(_ path: String) throws(VFSError) -> String {
        guard let node = resolve(path) else { throw VFSError.notFound(path: path) }
        guard !node.isDirectory else { throw VFSError.isDirectory(path: path) }
        // Live hook: the kernel log keeps growing after seed time, so the
        // syslog is rendered lazily from the boot log on every read.
        if VFS.normalize(path, cwd: "/") == "/var/log/syslog" {
            return Platform.services.bootLog.joined(separator: "\n")
        }
        return node.contents
    }

    /// Writes (creating or replacing) a regular file. The parent directory must exist.
    func write(_ path: String, contents: String) throws(VFSError) {
        let full = VFS.normalize(path, cwd: "/")
        if let existing = resolve(full) {
            guard !existing.isDirectory else { throw VFSError.isDirectory(path: path) }
            existing.contents = contents
            existing.modified = Platform.services.wallClockMs
            persistContents(of: existing, path: full)
            return
        }
        let base = VFS.basename(full)
        guard !base.isEmpty, base != "/" else { throw VFSError.isDirectory(path: path) }
        guard let parent = resolve(VFS.dirname(full)) else {
            throw VFSError.notFound(path: path)
        }
        guard parent.isDirectory else { throw VFSError.notDirectory(path: path) }
        let node = FSNode.file(base, contents)
        parent.children[base] = node
        persistNew(node: node, parent: parent, path: full)
    }

    // MARK: Mutation

    /// Creates a single directory level. Throws alreadyExists / notFound (missing parent).
    func mkdir(_ path: String) throws(VFSError) {
        let full = VFS.normalize(path, cwd: "/")
        if resolve(full) != nil { throw VFSError.alreadyExists(path: path) }
        let base = VFS.basename(full)
        guard !base.isEmpty, base != "/" else { throw VFSError.alreadyExists(path: path) }
        guard let parent = resolve(VFS.dirname(full)) else {
            throw VFSError.notFound(path: path)
        }
        guard parent.isDirectory else { throw VFSError.notDirectory(path: path) }
        let node = FSNode.dir(base)
        parent.children[base] = node
        persistNew(node: node, parent: parent, path: full)
    }

    /// Removes a file or an EMPTY directory. Throws notFound / directoryNotEmpty.
    func remove(_ path: String) throws(VFSError) {
        let full = VFS.normalize(path, cwd: "/")
        guard full != "/" else { throw VFSError.permissionDenied(path: path) }
        guard let target = resolve(full) else { throw VFSError.notFound(path: path) }
        if target.isDirectory && !target.children.isEmpty {
            throw VFSError.directoryNotEmpty(path: path)
        }
        persistRemove(target, path: full)
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

    // MARK: - Persistence (SwiftFS write-through)

    /// The one path that never touches the disk: the syslog is rendered live
    /// from Platform.services.bootLog on every read.
    private static let syslogPath = "/var/log/syslog"

    /// Replaces the tree with the on-disk inode contents. Returns false when
    /// the image holds nothing but the root inode (interrupted first format),
    /// in which case the caller reseeds and persists instead.
    @discardableResult
    fileprivate func hydrateFromDisk() -> Bool {
        let entries = SwiftFS.dumpInodes()
        guard entries.count > 1 else { return false }
        var nodes: [Int: FSNode] = [:]
        for e in entries { nodes[e.index] = makeNode(e) }
        for e in entries where e.index != 0 {
            guard let child = nodes[e.index] else { continue }
            // A dangling parent link should be impossible; re-home at root.
            (nodes[e.parent] ?? nodes[0])?.children[child.name] = child
        }
        guard let newRoot = nodes[0], newRoot.isDirectory else { return false }
        newRoot.name = "/"
        rootStorage = newRoot
        ensureSyslogNode()
        klog("[vfs] hydrated \(entries.count - 1) entries from SwiftFS")
        return true
    }

    /// Writes the entire current tree to a freshly formatted disk, assigning
    /// an inode to every node (except the syslog, which stays RAM-only).
    fileprivate func persistEntireTree() {
        let r = root   // forces the seed tree when this is the first access
        for child in r.children.values {
            persistSubtree(child, parentInode: 0, path: "/" + child.name)
        }
    }

    private func persistSubtree(_ node: FSNode, parentInode: Int, path: String) {
        if path == VFS.syslogPath { return }
        guard let idx = SwiftFS.create(name: node.name, parent: parentInode,
                                       isDirectory: node.isDirectory,
                                       executable: VFS.isExecutable(node),
                                       mtime: node.modified) else {
            klog("[vfs] persist failed for \(path)")
            return
        }
        node.inode = idx
        if node.isDirectory {
            for child in node.children.values {
                persistSubtree(child, parentInode: idx, path: path + "/" + child.name)
            }
        } else if !SwiftFS.writeFile(idx, Array(node.contents.utf8), mtime: node.modified) {
            klog("[vfs] persist write failed for \(path)")
        }
    }

    /// Write-through for a newly created node (file with contents, or dir).
    private func persistNew(node: FSNode, parent: FSNode, path: String) {
        guard Disk.mounted, parent.inode >= 0, path != VFS.syslogPath else { return }
        guard let idx = SwiftFS.create(name: node.name, parent: parent.inode,
                                       isDirectory: node.isDirectory,
                                       executable: VFS.isExecutable(node),
                                       mtime: node.modified) else {
            klog("[vfs] persist create failed for \(path)")
            return
        }
        node.inode = idx
        if !node.isDirectory,
           !SwiftFS.writeFile(idx, Array(node.contents.utf8), mtime: node.modified) {
            klog("[vfs] persist write failed for \(path)")
        }
    }

    /// Write-through for a contents update of an existing file.
    private func persistContents(of node: FSNode, path: String) {
        guard Disk.mounted, node.inode >= 0, path != VFS.syslogPath else { return }
        if !SwiftFS.writeFile(node.inode, Array(node.contents.utf8), mtime: node.modified) {
            klog("[vfs] persist write failed for \(path)")
        }
    }

    /// Write-through for a removal (frees the inode and its data span).
    private func persistRemove(_ node: FSNode, path: String) {
        guard Disk.mounted, node.inode >= 0, path != VFS.syslogPath else { return }
        if !SwiftFS.remove(node.inode) {
            klog("[vfs] persist remove failed for \(path)")
        }
    }

    private static func isExecutable(_ node: FSNode) -> Bool {
        !node.isDirectory && node.permissions.contains("x")
    }

    private func makeNode(_ e: SFInode) -> FSNode {
        let node: FSNode
        if e.isDirectory {
            node = FSNode(name: e.name, isDirectory: true, permissions: "drwxr-xr-x")
        } else {
            let bytes = SwiftFS.readFile(e.index) ?? []
            node = FSNode(name: e.name, isDirectory: false,
                          contents: String(decoding: bytes, as: UTF8.self),
                          permissions: e.executable ? "-rwxr-xr-x" : "-rw-r--r--")
        }
        node.inode = e.index
        node.modified = e.mtimeMs
        return node
    }

    /// The hydrated tree must contain /var/log/syslog (RAM-only, inode -1) so
    /// the path resolves for the live-boot-log hook in read().
    private func ensureSyslogNode() {
        guard let r = rootStorage else { return }
        if r.children["var"] == nil { r.children["var"] = FSNode.dir("var") }
        let varDir = r.children["var"]!
        if varDir.children["log"] == nil { varDir.children["log"] = FSNode.dir("log") }
        let logDir = varDir.children["log"]!
        if logDir.children["syslog"] == nil {
            logDir.children["syslog"] = FSNode.file("syslog", "")
        }
    }

    // MARK: Seed

    private static func seedTree() -> FSNode {
        let binNames = [
            "swish", "sh", "bash", "ls", "cat", "echo", "pwd", "cd", "mkdir", "rm",
            "cp", "mv", "touch", "hostname", "uname", "date", "df", "ps", "grep",
            "head", "tail", "whoami", "env", "export", "history", "clear", "sudo",
            "open", "help", "exit", "kill",
        ]
        let usrBinNames = ["find", "which", "man", "uptime", "free", "neofetch", "wc",
                           "nano", "top"]

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
        Welcome to SwiftOS 1.0 (kernel 1.0.0-aarch64)

         * Documentation:  /usr/share/doc
         * Support:        https://swiftos.dev/support
        """)

        let readme = FSNode.file("README.txt", """
        Welcome to SwiftOS!
        ===================

        This is your home directory. Everything on this system is written
        in Swift and runs on our own bare-metal kernel: the drivers, the
        window manager, this filesystem, and the terminal you are
        reading it in. No Linux, no Apple frameworks.

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

        // Contents are irrelevant: read() serves /var/log/syslog lazily from
        // Platform.services.bootLog so late boot lines appear. The node exists
        // so the path resolves for ls/stat.
        let syslog = FSNode.file("syslog", "")

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


// MARK: - Disk (boot-time storage integration)

/// Persistent-storage orchestration: brings up the virtio-blk device, mounts
/// the SwiftFS image if one exists, formats and seeds it if the disk is
/// blank, and flips the VFS between hydrated, seeded-and-persisted, and
/// RAM-only modes. Every failure is non-fatal — the system keeps running
/// with the seeded in-memory tree exactly as before.
///
/// Idempotent. Intended to be called once from kmain during boot; the VFS
/// also invokes it lazily on first access, so storage works either way.
enum Disk {
    /// True once a valid SwiftFS image is mounted and write-through is live.
    static private(set) var mounted = false
    private static var didInit = false

    @discardableResult
    static func initAndMount() -> Bool {
        if didInit { return mounted }
        didInit = true
        guard BlockDev.initBlockDev() else {
            klog("[disk] no block device — filesystem stays RAM-only")
            return false
        }
        if SwiftFS.mount() {
            mounted = true
            if VFS.shared.hydrateFromDisk() {
                klog("[disk] persistent storage online")
            } else {
                // Valid but empty image (e.g. power cut during the first
                // seed): reseed in memory and write it through.
                VFS.shared.persistEntireTree()
                klog("[disk] empty image reseeded")
            }
        } else {
            klog("[disk] no valid SwiftFS image — formatting")
            guard SwiftFS.format() else {
                klog("[disk] format FAILED — filesystem stays RAM-only")
                return false
            }
            mounted = true
            VFS.shared.persistEntireTree()
            klog("[disk] fresh image formatted and seeded")
        }
        return true
    }
}
