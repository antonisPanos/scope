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

    /// What parses archives for Extract. Archives come from anywhere, so the
    /// app can run the parsing in a sandboxed service of its own; the engine
    /// opens the file, checks every entry's name and writes every file.
    public var archiveReaders: any ArchiveReaderOpening = LibArchiveReaders()
    /// What an extraction may hold in memory; lowered by tests.
    var extractionLimits = ExtractionLimits()
    /// Compression is isolated in the same sandboxed service in the app.
    /// The default keeps standalone engine clients/tests self-contained.
    public var archiveWriters: any ArchiveWriterOpening = LibArchiveWriters()
    /// Tests only: runs `diskutil` in place of `runTool`, so tests can check
    /// its arguments, and that it never ran, without mounting anything.
    var toolRunner: ToolRunner?
    /// Tests only: simulate slow path resolution at the I/O boundary.
    var readValidationHook: (@Sendable () -> Void)?

    /// Tests only: items for which the Trash refuses, as on a disk without
    /// one. Always nil in the app.
    var trashRefusal: (@Sendable (URL) -> Bool)?

    /// Where trashed items go: the system Trash in the app. Tests set a
    /// folder of their own, so nothing they trash can reach a real Trash.
    var trash: TrashLocation = .system

    enum TrashLocation: Sendable {
        case system
        /// Items are renamed into this folder, which must be on their disk.
        case folder(URL)
    }

    /// Tests only: an error number to fail reading a file's data with, as a
    /// failing disk would. Always nil in the app.
    var readFault: (@Sendable (String) -> Int32?)?

    /// Tests only: an error number to fail a copy's write with, given the
    /// file being written and the offset of the write, as a full disk
    /// (ENOSPC) or a failing one (EIO) would. Always nil in the app.
    var writeFault: (@Sendable (String, Int64) -> Int32?)?

    /// Tests only: model a copy sync syscall failure without changing paths.
    var copySyncFault: CopySyncFault?

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
            return try FinderTags.names(at: target)
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
            let renamed =
                Self.isSameItem(source.path, destination.path)
                ? renamex_np(source.path, destination.path, 0) == 0
                : Self.renameExclusively(source.path, to: destination.path)
            guard renamed else {
                throw FileEngineError.posix("Rename", source.path)
            }
            return destination
        }
    }

    /// Moves an item to `destination` (the full new path, not its folder).
    /// Only moves within one disk are supported for now; they are a single
    /// atomic rename. `puttingBack` marks an undo that takes a trashed item
    /// out of the Trash (`PathGuard.checkPutBack`).
    public func moveItem(at url: URL, to destination: URL, puttingBack: Bool = false) async throws {
        try await onIOThreads {
            let source = try puttingBack ? pathGuard.checkPutBack(url) : pathGuard.checkModifiable(url)
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
            guard Self.renameExclusively(source.path, to: target.path) else {
                throw FileEngineError.posix("Move", source.path)
            }
        }
    }

    /// Moves an item to the Trash and returns where it ended up. Scope never
    /// deletes outright, except on a disk with no Trash after the user
    /// confirmed it for the items named (`PermanentDelete.swift`).
    @discardableResult
    public func trashItem(at url: URL) async throws -> URL? {
        return try await onIOThreads {
            try moveToTrash(try pathGuard.checkModifiable(url))
        }
    }

    /// The one place items go to the Trash; `target` has passed the guard.
    func moveToTrash(_ target: URL) throws -> URL? {
        if let trashRefusal, trashRefusal(target) {
            throw CocoaError(.featureUnsupported, userInfo: [NSFilePathErrorKey: target.path])
        }
        switch trash {
        case .system:
            var resulting: NSURL?
            try FileManager.default.trashItem(at: target, resultingItemURL: &resulting)
            return resulting as URL?
        case .folder(let folder):
            let trashed = try pathGuard.checkWriteLocation(
                folder.appendingPathComponent(UUID().uuidString + "-" + target.lastPathComponent))
            guard Self.renameExclusively(target.path, to: trashed.path) else {
                throw FileEngineError.posix("Move to Trash", target.path)
            }
            return trashed
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
    /// renamed into place at the end. Before publication, cancellation or
    /// failure removes the partial; a PublishedCopyFinalizationError instead
    /// means the destination was published but its final sync failed.
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

        var job = CopyJob(
            progress: progress, control: control, readFault: readFault, writeFault: writeFault,
            syncFault: copySyncFault)
        let input = try CopyLocation(checked: source)
        let output = try CopyLocation(checked: target)
        // A named pipe or device file anywhere inside fails the copy here,
        // before a partial exists, rather than being left out of it.
        try job.measure(input, rejectingUnsupported: true)

        // The staging name never includes the destination's name: a legal
        // 255-byte name plus the prefix would exceed the disk's name limit.
        let partial = target.deletingLastPathComponent()
            .appendingPathComponent(Self.partialPrefix + UUID().uuidString)
        // The partial name must pass the guard like any other path we write.
        try pathGuard.checkWriteLocation(partial)

        // The staged copy is named by its destination in messages (and in the
        // tests' fault hook): its hidden name no longer says which item it is.
        let staged = CopyLocation(parent: output.parent, name: partial.lastPathComponent, path: target.path)
        let publishedIdentity: FileIdentity
        do {
            try job.copy(from: input, to: staged, relative: "")
            try Task.checkCancellation()
            try control?.waitWhilePaused()
            try output.validateParent(pathGuard: pathGuard)
            // A move verifies the copy here, while it still has its partial
            // name, so a cancel or a mismatch never leaves a second copy behind.
            try beforePlacing?(source, partial)
            try output.validateParent(pathGuard: pathGuard)
            guard let identity = job.partialIdentity else {
                throw FileEngineError.posix("Copy", target.path, EBUSY)
            }
            let current = try staged.info()
            guard CopyLocation.same(current, identity),
                staged.renameExclusively(to: output.name, isDirectory: identity.st_mode & S_IFMT == S_IFDIR)
            else {
                throw FileEngineError.posix("Copy", target.path)
            }
            let isDirectory = current.st_mode & S_IFMT == S_IFDIR
            publishedIdentity = FileIdentity(
                inode: UInt64(current.st_ino),
                modified: isDirectory
                    ? 0
                    : Int64(current.st_mtimespec.tv_sec) * 1_000_000_000
                        + Int64(current.st_mtimespec.tv_nsec),
                size: isDirectory ? 0 : Int64(current.st_size), device: UInt64(current.st_dev),
                kind: UInt32(current.st_mode & S_IFMT))
        } catch {
            do {
                try staged.removePartial(matching: job.partialIdentity)
            } catch {
                Self.logger.fault("Could not remove pinned partial: \(error.localizedDescription)")
            }
            throw error
        }
        control?.update { $0.currentItem = "Finalizing \(target.lastPathComponent)" }
        do {
            try job.finish(source: input, destination: output)
            try output.syncParent(fault: copySyncFault)
        } catch {
            throw PublishedCopyFinalizationError(
                destination: target, reason: error.localizedDescription, publishedIdentity: publishedIdentity)
        }
    }

    /// Total bytes and items under `urls`, as a copy would count them.
    public func measure(_ urls: [URL]) throws -> (bytes: Int64, items: Int) {
        var job = CopyJob(progress: nil, control: nil)
        for url in urls { try job.measure(CopyLocation(checked: pathGuard.checkLocation(url))) }
        return (job.state.bytesTotal, job.state.itemsTotal)
    }

    // MARK: - Helpers

    /// The longest file name, in UTF-8 bytes, that APFS and HFS+ accept.
    static let maxNameBytes = 255

    /// `base` + `tail` + `ext` (such as "photo" + " copy 2" + ".jpg") within
    /// `maxNameBytes`, so generated names stay legal when the original name
    /// is already near the limit. The base is shortened by whole characters
    /// first. When not even one of its characters fits beside the extension
    /// (a very long extension, or one large composed character), the
    /// extension goes too and the whole original name is shortened before
    /// the tail. In the last resort the name is the tail alone ("copy 2").
    static func fittingName(_ base: String, _ tail: String, extension ext: String = "") -> String {
        if let head = shortened(base, toFit: tail + ext) { return head + tail + ext }
        if var whole = shortened(base + ext, toFit: tail) {
            while whole.count > 1, whole.last == "." || whole.last == " " { whole.removeLast() }
            return whole + tail
        }
        return String(tail.drop { $0 == " " })
    }

    /// `text` without as few trailing characters as leave room for `rest`;
    /// nil when that would leave nothing of a non-empty `text`.
    private static func shortened(_ text: String, toFit rest: String) -> String? {
        var head = Substring(text)
        while head.utf8.count + rest.utf8.count > maxNameBytes {
            guard !head.isEmpty else { return nil }
            head = head.dropLast()
        }
        return head.isEmpty && !text.isEmpty ? nil : String(head)
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
            && name.utf8.count <= maxNameBytes
    }

    /// Renames `source` to `target` only if nothing is there; false with
    /// `errno` set otherwise. FAT and exFAT disks can't rename exclusively
    /// (ENOTSUP), so there the name is first claimed with an exclusive
    /// create, and the rename replaces only that empty placeholder.
    static func renameExclusively(_ source: String, to target: String) -> Bool {
        if renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 { return true }
        guard errno == ENOTSUP || errno == EINVAL, let info = lstatInfo(source) else { return false }
        let isFolder = info.st_mode & S_IFMT == S_IFDIR
        if isFolder {
            guard mkdir(target, 0o700) == 0 else { return false }
        } else {
            let placeholder = open(target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard placeholder >= 0 else { return false }
            close(placeholder)
        }
        if Darwin.rename(source, target) == 0 { return true }
        let failure = errno
        _ = isFolder ? rmdir(target) : unlink(target)
        errno = failure
        return false
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

    /// The file flags a copy takes over. UF_COMPRESSED describes how the
    /// original is stored, not the item: a copy is written uncompressed, and
    /// marking it compressed would make its contents unreadable.
    static func settableFlags(_ flags: UInt32) -> UInt32 {
        flags & ~UInt32(UF_COMPRESSED)
    }

    /// Whether an item carries an access control list.
    static func hasACL(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }

    private static let logger = Logger(subsystem: "com.antonispanos.scope", category: "FileEngine")
}
