import Foundation
import os

/// Progress of a running copy. Reported after every chunk and every item.
public struct CopyProgress: Sendable, Equatable {
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var itemsDone: Int
    public var itemsTotal: Int
    /// Path of the item being copied, relative to the copy's source.
    public var currentItem: String
}

/// All file system work goes through here, and every path it receives passes
/// the path guard first. The methods run on the engine's own I/O threads
/// (`IOExecutor`), never on the main thread and never on Swift's concurrency
/// pool, which blocking file system calls could use up.
public struct FileEngine: Sendable {
    public let pathGuard: PathGuard

    /// Items being copied are written under this prefix and renamed into place
    /// only when complete, so a cancelled or failed copy never leaves a
    /// half-written item under its real name.
    public static let partialPrefix = ".scope-partial-"

    /// Size of each read/write during a copy; cancellation is checked between chunks.
    public static let chunkSize = 4 * 1024 * 1024

    public init(pathGuard: PathGuard) {
        self.pathGuard = pathGuard
    }

    // MARK: - Listing

    public func contentsOfDirectory(at url: URL, includeHidden: Bool = true) async throws -> [FileItem] {
        return try await onIOThreads {
            let directory = try pathGuard.checkTarget(url)
            var options: FileManager.DirectoryEnumerationOptions = []
            if !includeHidden { options.insert(.skipsHiddenFiles) }
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: FileItem.resourceKeys, options: options)
            var items: [FileItem] = []
            items.reserveCapacity(urls.count)
            for (index, child) in urls.enumerated() {
                if index % 1024 == 0 { try Task.checkCancellation() }
                items.append(try FileItem(url: child))
            }
            return items
        }
    }

    /// Describes specific items, such as search or Spotlight results. Items
    /// the guard doesn't permit, or that no longer exist, are left out.
    public func items(at urls: [URL]) async throws -> [FileItem] {
        return try await onIOThreads {
            var items: [FileItem] = []
            items.reserveCapacity(urls.count)
            for (index, url) in urls.enumerated() {
                if index % 256 == 0 { try Task.checkCancellation() }
                guard pathGuard.permits(url), let item = try? FileItem(url: url) else { continue }
                items.append(item)
            }
            return items
        }
    }

    /// Finder tags of one item. Kept out of listings for speed; call it for
    /// the rows on screen.
    public func tags(for url: URL) async throws -> [String] {
        return try await onIOThreads {
            let target = try pathGuard.checkLocation(url)
            return try target.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        }
    }

    /// The whole contents of one file, for printing. Refuses folders and
    /// anything larger than `limit`, so a stray click can't load gigabytes.
    public func contents(of url: URL, limit: Int64 = 256 << 20) async throws -> Data {
        let target = try pathGuard.checkTarget(url)
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw FileEngineError.sourceMissing(target.path) }
        guard Int64(values.fileSize ?? 0) <= limit else { throw FileEngineError.tooLarge(target.path) }
        return try Data(contentsOf: target, options: .mappedIfSafe)
    }

    /// Describes one item, after the guard has checked it.
    public func item(at url: URL) async throws -> FileItem {
        return try await onIOThreads {
            try FileItem(url: pathGuard.checkTarget(url))
        }
    }

    // MARK: - Simple operations

    public func createFolder(at url: URL) async throws {
        try await onIOThreads {
            let target = try pathGuard.checkWriteLocation(url)
            guard mkdir(target.path, 0o755) == 0 else { throw FileEngineError.posix("Create folder", target.path) }
        }
    }

    /// Renames an item in place and returns its new URL.
    @discardableResult
    public func rename(_ url: URL, to newName: String) async throws -> URL {
        return try await onIOThreads {
            guard Self.isValidName(newName) else { throw FileEngineError.invalidName(newName) }
            let source = try pathGuard.checkModifiable(url)
            let destination = try pathGuard.checkWriteLocation(
                source.deletingLastPathComponent().appendingPathComponent(newName))
            // A case-only rename on a case-insensitive disk finds the item itself at
            // the destination, so it must not use the exclusive rename.
            let flags: UInt32 = Self.isSameItem(source.path, destination.path) ? 0 : UInt32(RENAME_EXCL)
            guard renamex_np(source.path, destination.path, flags) == 0 else {
                throw FileEngineError.posix("Rename", source.path)
            }
            return destination
        }
    }

    /// Moves an item to `destination` (the full new path, not its folder).
    /// Only moves within one disk are supported for now; they are a single
    /// atomic rename.
    public func moveItem(at url: URL, to destination: URL) async throws {
        try await onIOThreads {
            let source = try pathGuard.checkModifiable(url)
            let target = try pathGuard.checkWriteLocation(destination)
            guard Self.lstatInfo(source.path) != nil else { throw FileEngineError.sourceMissing(source.path) }
            let targetFolder = target.deletingLastPathComponent().path
            guard let sourceDevice = Self.lstatInfo(source.path)?.st_dev,
                let targetDevice = Self.lstatInfo(targetFolder)?.st_dev
            else {
                throw FileEngineError.sourceMissing(targetFolder)
            }
            guard sourceDevice == targetDevice else { throw FileEngineError.crossVolumeMoveNotSupported(source.path) }
            guard !Self.isInside(target.path, source.path) else {
                throw FileEngineError.cannotCopyIntoItself(source.path)
            }
            guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                throw FileEngineError.posix("Move", source.path)
            }
        }
    }

    /// Moves an item to the Trash and returns where it ended up. Scope never
    /// deletes outright.
    @discardableResult
    public func trashItem(at url: URL) async throws -> URL? {
        return try await onIOThreads {
            let target = try pathGuard.checkModifiable(url)
            var resulting: NSURL?
            try FileManager.default.trashItem(at: target, resultingItemURL: &resulting)
            return resulting as URL?
        }
    }

    /// Removes partial items a crashed or killed copy left in `directory`.
    /// Returns how many were removed.
    @discardableResult
    public func removeLeftoverPartials(in directory: URL) async throws -> Int {
        return try await onIOThreads {
            try pathGuard.checkWriteLocation(directory)
            let folder = try pathGuard.checkTarget(directory)
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            var removed = 0
            for name in names where name.hasPrefix(Self.partialPrefix) {
                let partial = try pathGuard.checkWriteLocation(folder.appendingPathComponent(name))
                try FileManager.default.removeItem(at: partial)
                removed += 1
            }
            return removed
        }
    }

    // MARK: - Copy

    /// Copies `url` to `destination` (the full new path, not its folder).
    ///
    /// Within one APFS volume, files are cloned, which is instant and takes
    /// no extra space. Sparse files stay sparse. Symlinks are copied as
    /// links, never followed. Permissions, extended
    /// attributes (including Finder tags and resource forks), ACLs, dates and
    /// file flags are kept. The copy is written under a hidden partial name and
    /// renamed into place at the end; on cancel or failure the partial item is
    /// removed and the destination is left as it was.
    public func copyItem(
        at url: URL,
        to destination: URL,
        progress: (@Sendable (CopyProgress) -> Void)? = nil
    ) async throws {
        try await onIOThreads {
            try copyItem(at: url, to: destination, control: nil, progress: progress)
        }
    }

    /// The copy itself, synchronous so it can run inside an operation; checks
    /// for cancellation and pauses between chunks.
    func copyItem(
        at url: URL,
        to destination: URL,
        control: OperationControl?,
        progress: (@Sendable (CopyProgress) -> Void)?,
        replacingExisting: Bool = false,
        beforePlacing: ((_ source: URL, _ partial: URL) throws -> Void)? = nil
    ) throws {
        let source = try pathGuard.checkLocation(url)
        let target = try pathGuard.checkWriteLocation(destination)
        guard Self.lstatInfo(source.path) != nil else { throw FileEngineError.sourceMissing(source.path) }
        // When replacing, `beforePlacing` must move the existing item away:
        // the final rename below still never overwrites.
        guard replacingExisting || Self.lstatInfo(target.path) == nil else {
            throw FileEngineError.destinationExists(target.path)
        }
        guard !Self.isInside(target.path, source.path) else { throw FileEngineError.cannotCopyIntoItself(source.path) }

        var job = CopyJob(progress: progress, control: control)
        try job.measure(source.path)

        let partial = target.deletingLastPathComponent()
            .appendingPathComponent(Self.partialPrefix + UUID().uuidString + "-" + target.lastPathComponent)
        // The partial name must pass the guard like any other path we write.
        try pathGuard.checkWriteLocation(partial)

        do {
            try job.copy(from: source.path, to: partial.path, relative: "")
            // A move verifies the copy here, while it still has its partial
            // name, so a cancel or a mismatch never leaves a second copy behind.
            try beforePlacing?(source, partial)
            guard renamex_np(partial.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                throw FileEngineError.posix("Copy", target.path)
            }
        } catch {
            Self.removeQuietly(partial.path)
            throw error
        }
        // The files are synced as they're written; this makes the rename
        // itself survive a power cut, before a move trashes the original.
        Self.syncFolder(target.deletingLastPathComponent().path)
        job.finish(at: target.path)
    }

    /// Total bytes and items under `urls`, as a copy would count them.
    public func measure(_ urls: [URL]) throws -> (bytes: Int64, items: Int) {
        var job = CopyJob(progress: nil, control: nil)
        for url in urls { try job.measure(try pathGuard.checkLocation(url).path) }
        return (job.state.bytesTotal, job.state.itemsTotal)
    }

    // MARK: - Helpers

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
            && name.utf8.count <= 255
    }

    /// Asks the disk to write out a folder's entries (new names, renames).
    /// Best effort: a disk that can't sync folders is not an error.
    static func syncFolder(_ path: String) {
        let folder = open(path, O_RDONLY | O_DIRECTORY)
        guard folder >= 0 else { return }
        _ = fsync(folder)
        close(folder)
    }

    static func lstatInfo(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    static func isSameItem(_ a: String, _ b: String) -> Bool {
        guard let x = lstatInfo(a), let y = lstatInfo(b) else { return false }
        return x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    /// Whether `path` is `folder` or lies inside it.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    static func removeQuietly(_ path: String) {
        // Partial items never carry locked flags, ACLs or read-only folder modes
        // (those are applied after the final rename), so a plain removal should
        // work. If something still blocks it, clear those and try once more.
        if (try? FileManager.default.removeItem(atPath: path)) != nil || lstatInfo(path) == nil { return }
        clearProtections(path)
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            logger.fault("Couldn't remove the partial item \(path, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// Clears file flags and ACLs, and makes folders writable, through a tree.
    private static func clearProtections(_ path: String) {
        guard let info = lstatInfo(path) else { return }
        _ = lchflags(path, 0)
        if let empty = acl_init(0) {
            _ = acl_set_link_np(path, ACL_TYPE_EXTENDED, empty)
            acl_free(UnsafeMutableRawPointer(empty))
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return }
        _ = chmod(path, 0o700)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            clearProtections(path + "/" + name)
        }
    }

    /// Whether an item carries an access control list.
    static func hasACL(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }

    private static let logger = Logger(subsystem: "com.antonispanos.scope", category: "FileEngine")
}

/// State of one copy: totals, progress, and the metadata that may only be
/// applied once the copy is in place.
private struct CopyJob {
    let progressHandler: (@Sendable (CopyProgress) -> Void)?
    var state = CopyProgress(bytesDone: 0, bytesTotal: 0, itemsDone: 0, itemsTotal: 0, currentItem: "")

    /// Folder metadata and file flags, applied after the final rename, deepest
    /// first. Applying them earlier would make a cancelled copy impossible to
    /// clean up (a locked file or a read-only folder can't be removed).
    var deferred: [(relative: String, source: String, isDirectory: Bool, flags: UInt32, hasACL: Bool)] = []

    let control: OperationControl?

    init(progress: (@Sendable (CopyProgress) -> Void)?, control: OperationControl?) {
        self.progressHandler = progress
        self.control = control
    }

    mutating func measure(_ path: String) throws {
        try Task.checkCancellation()
        guard let info = FileEngine.lstatInfo(path) else { throw FileEngineError.posix("Read", path) }
        state.itemsTotal += 1
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            for name in try FileManager.default.contentsOfDirectory(atPath: path) {
                try measure(path + "/" + name)
            }
        case S_IFREG:
            state.bytesTotal += Int64(info.st_size)
        default:
            break
        }
    }

    mutating func copy(from source: String, to destination: String, relative: String) throws {
        try Task.checkCancellation()
        guard let info = FileEngine.lstatInfo(source) else { throw FileEngineError.posix("Read", source) }
        state.currentItem = relative
        report()

        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            guard mkdir(destination, 0o700) == 0 else { throw FileEngineError.posix("Create folder", destination) }
            let children = try FileManager.default.contentsOfDirectory(atPath: source).sorted()
            for name in children {
                let childRelative = relative.isEmpty ? name : relative + "/" + name
                try copy(from: source + "/" + name, to: destination + "/" + name, relative: childRelative)
            }
            FileEngine.syncFolder(destination)
            deferred.append((relative, source, true, info.st_flags, false))
        case S_IFLNK:
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlink(source, &buffer, buffer.count - 1)
            guard length >= 0 else { throw FileEngineError.posix("Read link", source) }
            buffer[length] = 0
            guard symlink(buffer, destination) == 0 else { throw FileEngineError.posix("Create link", destination) }
            _ = copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW))
        case S_IFREG:
            try copyData(from: source, to: destination, info: info)
            try copyMetadata(from: source, to: destination, info: info)
            // An ACL can forbid deleting the file, so like flags it is applied
            // only once the copy is in place (otherwise a cancelled copy
            // couldn't be cleaned up).
            let hasACL = FileEngine.hasACL(source)
            if info.st_flags != 0 || hasACL { deferred.append((relative, source, false, info.st_flags, hasACL)) }
        default:
            // Sockets, pipes and device nodes are not copied.
            break
        }
        state.itemsDone += 1
        report()
    }

    private mutating func copyData(from source: String, to destination: String, info: stat) throws {
        let size = off_t(info.st_size)
        // Locked files take the copy path, so the flag can be held back as usual.
        if info.st_flags == 0, clone(from: source, to: destination) {
            state.bytesDone += Int64(size)
            report()
            return
        }

        let input = open(source, O_RDONLY)
        guard input >= 0 else { throw FileEngineError.posix("Open", source) }
        defer { close(input) }
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard output >= 0 else { throw FileEngineError.posix("Create", destination) }
        defer { close(output) }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: FileEngine.chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        // A sparse file (VM disks, databases, disk image bands) has holes that
        // read as zeros. Only its data is copied, so the copy stays as small.
        if Int64(info.st_blocks) * 512 < Int64(size) {
            var offset: off_t = 0
            while offset < size {
                let start = lseek(input, offset, SEEK_DATA)
                if start < 0 {
                    // ENXIO: nothing but a hole from here to the end.
                    guard errno == ENXIO else { throw FileEngineError.posix("Read", source) }
                    break
                }
                var end = lseek(input, start, SEEK_HOLE)
                if end < 0 || end > size { end = size }
                state.bytesDone += Int64(start - offset)
                try copyRange(
                    input, output, from: start, to: end, buffer: buffer, source: source, destination: destination)
                offset = end
            }
            state.bytesDone += Int64(max(0, size - offset))
            // The file ends at its full size even when it ends in a hole.
            guard ftruncate(output, size) == 0 else { throw FileEngineError.posix("Write", destination) }
        } else {
            try copyRange(input, output, from: 0, to: nil, buffer: buffer, source: source, destination: destination)
        }
        guard fsync(output) == 0 else { throw FileEngineError.posix("Write", destination) }
    }

    /// Clones a file on the same APFS volume: instant, and the clone shares
    /// the original's storage until either changes. False when the disk
    /// can't (another volume, or not APFS); nothing is created then.
    private func clone(from source: String, to destination: String) -> Bool {
        guard clonefile(source, destination, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else { return false }
        // A clone carries the original's ACL. Like any copy's, it is set again
        // by the metadata steps, at the point where a cancel can still clean up.
        if let empty = acl_init(0) {
            _ = acl_set_link_np(destination, ACL_TYPE_EXTENDED, empty)
            acl_free(UnsafeMutableRawPointer(empty))
        }
        return true
    }

    /// Copies bytes `start..<end` (to the end of the file when `end` is nil),
    /// checking for cancel and pause between chunks.
    private mutating func copyRange(
        _ input: Int32, _ output: Int32, from start: off_t, to end: off_t?,
        buffer: UnsafeMutableRawPointer, source: String, destination: String
    ) throws {
        var offset = start
        while end.map({ offset < $0 }) ?? true {
            try Task.checkCancellation()
            try control?.waitWhilePaused()
            let wanted = end.map { min(FileEngine.chunkSize, Int($0 - offset)) } ?? FileEngine.chunkSize
            let read = pread(input, buffer, wanted, offset)
            if read < 0 {
                if errno == EINTR { continue }
                throw FileEngineError.posix("Read", source)
            }
            if read == 0 { break }
            var written = 0
            while written < read {
                let result = pwrite(output, buffer + written, read - written, offset + off_t(written))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw FileEngineError.posix("Write", destination)
                }
                written += result
            }
            offset += off_t(read)
            state.bytesDone += Int64(read)
            report()
        }
    }

    /// Permissions, extended attributes and dates for a file. Its ACL comes
    /// later, in `finish`.
    private func copyMetadata(from source: String, to destination: String, info: stat) throws {
        guard copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR)) == 0 else {
            throw FileEngineError.posix("Copy attributes", destination)
        }
        // copyfile(3) can carry file flags along with the security info. Flags
        // such as "locked" are applied only once the copy is in place.
        if info.st_flags != 0 { _ = lchflags(destination, 0) }
        try Self.copyTimes(info, to: destination)
    }

    private static func copyTimes(_ info: stat, to destination: String) throws {
        var times = [info.st_atimespec, info.st_mtimespec]
        guard utimensat(AT_FDCWD, destination, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw FileEngineError.posix("Set dates", destination)
        }
    }

    /// Applies the deferred folder metadata and file flags under the final path.
    /// The copy is complete at this point, so a failure here is not an error
    /// worth undoing it for.
    func finish(at root: String) {
        // `deferred` is in post-order (children before their folder), which is
        // the order folder dates need: setting them last keeps them intact.
        for entry in deferred {
            let path = entry.relative.isEmpty ? root : root + "/" + entry.relative
            if entry.isDirectory {
                _ = copyfile(entry.source, path, nil, copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR))
                if let info = FileEngine.lstatInfo(entry.source) { try? Self.copyTimes(info, to: path) }
            } else if entry.hasACL {
                _ = copyfile(entry.source, path, nil, copyfile_flags_t(COPYFILE_ACL))
            }
            if entry.flags != 0 { _ = lchflags(path, entry.flags) }
        }
    }

    private func report() {
        progressHandler?(state)
    }
}
