import Foundation
import CoreGraphics

/// STUB — the filesystem/shell subsystem replaces the storage half of this file with a
/// real in-memory Linux-like tree. Keep ALL of this API EXACTLY; the shell, file
/// manager, and text editor compile against it. The static path helpers below are
/// already final implementations — keep them.

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

final class VFS {
    static let shared = VFS()
    private init() {}

    // MARK: Query

    /// Lists the contents of the directory at `path` (absolute or relative-to-root).
    /// Throws notFound / notDirectory.
    func list(_ path: String) throws -> [VNode] { [] }

    /// Metadata for a single path. Throws notFound.
    func node(at path: String) throws -> VNode {
        throw VFSError.notFound(path: path)
    }

    func exists(_ path: String) -> Bool { false }
    func isDirectory(_ path: String) -> Bool { false }

    // MARK: Contents

    /// Reads a regular file as UTF-8 text. Throws notFound / isDirectory.
    func read(_ path: String) throws -> String {
        throw VFSError.notFound(path: path)
    }

    /// Writes (creating or replacing) a regular file. The parent directory must exist.
    func write(_ path: String, contents: String) throws {
        throw VFSError.permissionDenied(path: path)
    }

    // MARK: Mutation

    /// Creates a single directory level. Throws alreadyExists / notFound (missing parent).
    func mkdir(_ path: String) throws {
        throw VFSError.permissionDenied(path: path)
    }

    /// Removes a file or an EMPTY directory. Throws notFound / directoryNotEmpty.
    func remove(_ path: String) throws {
        throw VFSError.notFound(path: path)
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
}
