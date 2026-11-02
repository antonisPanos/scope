import CryptoKit
import Foundation

/// Versions a directory tree without following symlinks, including links
/// swapped in during traversal. Only descriptors authorize descent.
enum DirectoryVersion {
    static func read(_ url: URL, expected: stat) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { throw FileEngineError.posix("Read undo version", url.path) }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, same(opened, expected) else {
            throw FileEngineError.posix("Directory changed", url.path, EBUSY)
        }
        var hash = SHA256()
        try visit(descriptor, hash: &hash)
        return Data(hash.finalize())
    }

    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode & S_IFMT == b.st_mode & S_IFMT
    }

    private static func visit(_ descriptor: Int32, hash: inout SHA256) throws {
        try Task.checkCancellation()
        let reader = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard reader >= 0 else { throw FileEngineError.posix("Read undo version", "directory") }
        guard let stream = fdopendir(reader) else {
            close(reader)
            throw FileEngineError.posix("Read undo version", "directory")
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw FileEngineError.posix("Read undo version", "directory") }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        hash.update(data: Data("directory \(names.count)\n".utf8))
        for name in names.sorted() {
            try Task.checkCancellation()
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw FileEngineError.posix("Read undo version", name)
            }
            let directory = info.st_mode & S_IFMT == S_IFDIR
            // Directory timestamps change when a later operation adds and
            // then removes an item. Descendant names capture those changes.
            let version = directory ? "" : "\(info.st_size) \(info.st_mtimespec.tv_sec) \(info.st_mtimespec.tv_nsec)"
            let record =
                "\(name.utf8.count):\(name) \(info.st_dev) \(info.st_ino) \(info.st_mode) \(info.st_flags) \(version)\n"
            hash.update(data: Data(record.utf8))
            if directory {
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw FileEngineError.posix("Read undo version", name) }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, same(opened, info) else {
                    throw FileEngineError.posix("Directory changed", name, EBUSY)
                }
                try visit(child, hash: &hash)
            }
        }
    }
}
