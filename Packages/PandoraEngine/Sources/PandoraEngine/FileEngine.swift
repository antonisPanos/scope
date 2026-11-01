import Foundation

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
/// the path guard first. The methods are nonisolated async functions, so they
/// run on the concurrency pool and never on the main thread.
public struct FileEngine: Sendable {
    public let pathGuard: PathGuard

    /// Items being copied are written under this prefix and renamed into place
    /// only when complete, so a cancelled or failed copy never leaves a
    /// half-written item under its real name.
    public static let partialPrefix = ".pandora-partial-"

    /// Size of each read/write during a copy; cancellation is checked between chunks.
    public static let chunkSize = 4 * 1024 * 1024

    public init(pathGuard: PathGuard) {
        self.pathGuard = pathGuard
    }

    // MARK: - Listing

    public func contentsOfDirectory(at url: URL, includeHidden: Bool = true) async throws -> [FileItem] {
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

    // MARK: - Simple operations

    public func createFolder(at url: URL) async throws {
        let target = try pathGuard.checkWriteLocation(url)
        guard mkdir(target.path, 0o755) == 0 else { throw FileEngineError.posix("Create folder", target.path) }
    }

    /// Renames an item in place and returns its new URL.
    @discardableResult
    public func rename(_ url: URL, to newName: String) async throws -> URL {
        guard Self.isValidName(newName) else { throw FileEngineError.invalidName(newName) }
        let source = try pathGuard.checkWriteLocation(url)
        let destination = try pathGuard.checkWriteLocation(source.deletingLastPathComponent().appendingPathComponent(newName))
        // A case-only rename on a case-insensitive disk finds the item itself at
        // the destination, so it must not use the exclusive rename.
        let flags: UInt32 = Self.isSameItem(source.path, destination.path) ? 0 : UInt32(RENAME_EXCL)
        guard renamex_np(source.path, destination.path, flags) == 0 else {
            throw FileEngineError.posix("Rename", source.path)
        }
        return destination
    }

    /// Moves an item to `destination` (the full new path, not its folder).
    /// Only moves within one disk are supported for now; they are a single
    /// atomic rename.
    public func moveItem(at url: URL, to destination: URL) async throws {
        let source = try pathGuard.checkWriteLocation(url)
        let target = try pathGuard.checkWriteLocation(destination)
        guard Self.lstatInfo(source.path) != nil else { throw FileEngineError.sourceMissing(source.path) }
        let targetFolder = target.deletingLastPathComponent().path
        guard let sourceDevice = Self.lstatInfo(source.path)?.st_dev,
              let targetDevice = Self.lstatInfo(targetFolder)?.st_dev else {
            throw FileEngineError.sourceMissing(targetFolder)
        }
        guard sourceDevice == targetDevice else { throw FileEngineError.crossVolumeMoveNotSupported(source.path) }
        guard !Self.isInside(target.path, source.path) else { throw FileEngineError.cannotCopyIntoItself(source.path) }
        guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            throw FileEngineError.posix("Move", source.path)
        }
    }

    /// Moves an item to the Trash and returns where it ended up. Pandora never
    /// deletes outright.
    @discardableResult
    public func trashItem(at url: URL) async throws -> URL? {
        let target = try pathGuard.checkWriteLocation(url)
        var resulting: NSURL?
        try FileManager.default.trashItem(at: target, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Removes partial items a crashed or killed copy left in `directory`.
    /// Returns how many were removed.
    @discardableResult
    public func removeLeftoverPartials(in directory: URL) async throws -> Int {
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

    // MARK: - Copy

    /// Copies `url` to `destination` (the full new path, not its folder).
    ///
    /// Symlinks are copied as links, never followed. Permissions, extended
    /// attributes (including Finder tags and resource forks), ACLs, dates and
    /// file flags are kept. The copy is written under a hidden partial name and
    /// renamed into place at the end; on cancel or failure the partial item is
    /// removed and the destination is left as it was.
    public func copyItem(
        at url: URL,
        to destination: URL,
        progress: (@Sendable (CopyProgress) -> Void)? = nil
    ) async throws {
        let source = try pathGuard.checkLocation(url)
        let target = try pathGuard.checkWriteLocation(destination)
        guard Self.lstatInfo(source.path) != nil else { throw FileEngineError.sourceMissing(source.path) }
        guard Self.lstatInfo(target.path) == nil else { throw FileEngineError.destinationExists(target.path) }
        guard !Self.isInside(target.path, source.path) else { throw FileEngineError.cannotCopyIntoItself(source.path) }

        var job = CopyJob(progress: progress)
        try job.measure(source.path)

        let partial = target.deletingLastPathComponent()
            .appendingPathComponent(Self.partialPrefix + UUID().uuidString + "-" + target.lastPathComponent)
        // The partial name must pass the guard like any other path we write.
        try pathGuard.checkWriteLocation(partial)

        do {
            try job.copy(from: source.path, to: partial.path, relative: "")
            guard renamex_np(partial.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                throw FileEngineError.posix("Copy", target.path)
            }
        } catch {
            Self.removeQuietly(partial.path)
            throw error
        }
        job.finish(at: target.path)
    }

    // MARK: - Helpers

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
            && name.utf8.count <= 255
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
        // Partial items never carry locked flags or read-only folder modes (those
        // are applied after the final rename), so a plain removal works.
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// State of one copy: totals, progress, and the metadata that may only be
/// applied once the copy is in place.
private struct CopyJob {
    let progressHandler: (@Sendable (CopyProgress) -> Void)?
    var state = CopyProgress(bytesDone: 0, bytesTotal: 0, itemsDone: 0, itemsTotal: 0, currentItem: "")

    /// Folder metadata and file flags, applied after the final rename, deepest
    /// first. Applying them earlier would make a cancelled copy impossible to
    /// clean up (a locked file or a read-only folder can't be removed).
    var deferred: [(relative: String, source: String, isDirectory: Bool, flags: UInt32)] = []

    init(progress: (@Sendable (CopyProgress) -> Void)?) {
        self.progressHandler = progress
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
            deferred.append((relative, source, true, info.st_flags))
        case S_IFLNK:
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlink(source, &buffer, buffer.count - 1)
            guard length >= 0 else { throw FileEngineError.posix("Read link", source) }
            buffer[length] = 0
            guard symlink(buffer, destination) == 0 else { throw FileEngineError.posix("Create link", destination) }
            _ = copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW))
        case S_IFREG:
            try copyData(from: source, to: destination)
            try copyMetadata(from: source, to: destination, info: info)
            if info.st_flags != 0 { deferred.append((relative, source, false, info.st_flags)) }
        default:
            // Sockets, pipes and device nodes are not copied.
            break
        }
        state.itemsDone += 1
        report()
    }

    private mutating func copyData(from source: String, to destination: String) throws {
        let input = open(source, O_RDONLY)
        guard input >= 0 else { throw FileEngineError.posix("Open", source) }
        defer { close(input) }
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard output >= 0 else { throw FileEngineError.posix("Create", destination) }
        defer { close(output) }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: FileEngine.chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            try Task.checkCancellation()
            let read = Darwin.read(input, buffer, FileEngine.chunkSize)
            if read < 0 {
                if errno == EINTR { continue }
                throw FileEngineError.posix("Read", source)
            }
            if read == 0 { break }
            var written = 0
            while written < read {
                let result = write(output, buffer + written, read - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw FileEngineError.posix("Write", destination)
                }
                written += result
            }
            state.bytesDone += Int64(read)
            report()
        }
        guard fsync(output) == 0 else { throw FileEngineError.posix("Write", destination) }
    }

    /// Permissions, ACLs, extended attributes and dates for a file.
    private func copyMetadata(from source: String, to destination: String, info: stat) throws {
        guard copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR)) == 0 else {
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
            }
            if entry.flags != 0 { _ = lchflags(path, entry.flags) }
        }
    }

    private func report() {
        progressHandler?(state)
    }
}
