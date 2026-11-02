import CryptoKit
import Foundation
import Testing

@testable import ScopeEngine

/// A fresh temporary folder per test, removed afterwards. Its resolved path is
/// used everywhere so comparisons don't trip over /var vs /private/var.
final class Sandbox {
    let root: URL
    /// Where `engine` puts trashed items: a folder next to `root`, so a test
    /// that trashes something here can't reach the user's real Trash.
    let trash: URL
    let engine: FileEngine

    /// A fresh folder in the system temporary folder, or inside `parent`.
    init(in parent: URL = FileManager.default.temporaryDirectory) throws {
        let base = parent.appendingPathComponent("ScopeEngineTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // resolvingSymlinksInPath() keeps /var instead of /private/var, so use realpath(3).
        let resolved = try #require(realpath(base.path, nil))
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved))
        trash = URL(fileURLWithPath: root.path + "-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var engine = FileEngine(pathGuard: .restricted(to: [root, trash]))
        engine.trash = .folder(trash)
        self.engine = engine
    }

    deinit {
        // Clear flags and modes the tests set so everything can be removed.
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in enumerator {
                let path = root.path + "/" + relative
                _ = lchflags(path, 0)
                if FileEngine.lstatInfo(path).map({ $0.st_mode & S_IFMT == S_IFDIR }) == true {
                    chmod(path, 0o755)
                }
            }
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: trash)
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    @discardableResult
    func write(_ relative: String, _ contents: String) throws -> URL {
        try write(relative, Data(contents.utf8))
    }

    @discardableResult
    func write(_ relative: String, _ data: Data) throws -> URL {
        let target = url(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }

    func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
    }

    func symlink(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url(relative).path, withDestinationPath: destination)
    }

    func exists(_ relative: String) -> Bool {
        FileEngine.lstatInfo(url(relative).path) != nil
    }

    func names(in relative: String = "") throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url(relative).path).sorted()
    }
}

/// A description of a file tree precise enough to compare two trees exactly:
/// types, contents, link targets, modes, flags and extended attributes.
struct TreeSnapshot: Equatable, CustomStringConvertible {
    struct Entry: Equatable {
        var kind: String
        var mode: UInt16
        var flags: UInt32
        var contentHash: String?
        var linkTarget: String?
        var xattrs: [String: Data]
    }

    var entries: [String: Entry]

    init(_ root: URL) throws {
        entries = [:]
        try visit(root.path, relative: ".")
    }

    private mutating func visit(_ path: String, relative: String) throws {
        guard let info = FileEngine.lstatInfo(path) else { throw CocoaError(.fileNoSuchFile) }
        var entry = Entry(
            kind: "other", mode: info.st_mode & 0o7777, flags: info.st_flags,
            contentHash: nil, linkTarget: nil, xattrs: Self.xattrs(path))
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            entry.kind = "dir"
            for name in try FileManager.default.contentsOfDirectory(atPath: path) {
                try visit(path + "/" + name, relative: relative == "." ? name : relative + "/" + name)
            }
        case S_IFREG:
            entry.kind = "file"
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            entry.contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case S_IFLNK:
            entry.kind = "link"
            entry.linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: path)
        default:
            break
        }
        entries[relative] = entry
    }

    private static func xattrs(_ path: String) -> [String: Data] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [:] }
        var names = [CChar](repeating: 0, count: size)
        listxattr(path, &names, size, XATTR_NOFOLLOW)
        var result: [String: Data] = [:]
        let bytes = names.map { UInt8(bitPattern: $0) }
        for nameBytes in bytes.split(separator: 0) {
            let name = String(decoding: nameBytes, as: UTF8.self)
            let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { continue }
            var value = Data(count: length)
            _ = value.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
            result[name] = value
        }
        return result
    }

    var description: String {
        entries.keys.sorted().map { "\($0): \(entries[$0]!)" }.joined(separator: "\n")
    }
}

func setXattr(_ url: URL, _ name: String, _ value: String) {
    let data = Array(value.utf8)
    setxattr(url.path, name, data, data.count, 0, XATTR_NOFOLLOW)
}
