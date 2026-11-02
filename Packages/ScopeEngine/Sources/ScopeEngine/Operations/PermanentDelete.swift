import Foundation

/// Items on a disk with no Trash that a delete would have to remove for good.
/// The app asks about exactly these; nothing else is ever removed outright.
public struct PermanentDeletion: Sendable, Equatable {
    /// The items, all on one disk.
    public let items: [URL]
    /// The disk's name, for the question.
    public let volume: String

    public init(items: [URL], volume: String) {
        self.items = items
        self.volume = volume
    }
}

/// Answers whether to delete items for good on a disk with no Trash. Only
/// true removes them, and only the items asked about.
public typealias PermanentDeletionConfirmer = @Sendable (PermanentDeletion) async -> Bool

/// Deleting on disks that have no Trash, such as some network shares and
/// disk images. Scope moves items to the Trash; only when the disk refuses
/// does it ask, naming the disk and every item, before removing them.
extension FileEngine {
    /// Moves items to the Trash. Where a disk has no Trash, asks once for
    /// that disk's remaining items and removes them for good only on a yes.
    func trash(
        _ items: [URL], control: OperationControl, undo: UndoRecorder, confirm: PermanentDeletionConfirmer
    ) async throws {
        control.update { $0.itemsTotal = items.count }
        var approved: Set<String> = []
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let original = try pathGuard.checkWriteLocation(item)
            control.update { $0.currentItem = original.lastPathComponent }
            do {
                if let trashed = try await trashItem(at: original) {
                    undo.add(.putBack(trashed: trashed, original: original))
                }
            } catch let error where Self.isTrashUnavailable(error) {
                if !approved.contains(original.path) {
                    let request = permanentDeletion(of: items[index...], like: original)
                    let yes = await confirm(request)
                    // A cancel while the question was open wins over the answer.
                    try Task.checkCancellation()
                    guard yes else { throw OperationError.noTrash(request.volume) }
                    approved.formUnion(request.items.map(\.path))
                }
                try deletePermanently(original)
            }
            control.update { $0.itemsDone += 1 }
        }
    }

    /// Whether an error from `trashItem` means the disk has no Trash, rather
    /// than that this one item couldn't go.
    static func isTrashUnavailable(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.featureUnsupported.rawValue { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOTSUP) || error.code == Int(EOPNOTSUPP) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error {
            return isTrashUnavailable(underlying)
        }
        return false
    }

    /// The items still to delete that are on the same disk as `first`.
    private func permanentDeletion(of items: ArraySlice<URL>, like first: URL) -> PermanentDeletion {
        let device = Self.lstatInfo(first.path)?.st_dev
        let sameDisk = items.compactMap { item -> URL? in
            guard let url = try? pathGuard.checkWriteLocation(item),
                device != nil, Self.lstatInfo(url.path)?.st_dev == device
            else { return nil }
            return url
        }
        return PermanentDeletion(items: sameDisk.isEmpty ? [first] : sameDisk, volume: Self.volumeName(of: first))
    }

    static func volumeName(of url: URL) -> String {
        var info = statfs()
        guard statfs(url.deletingLastPathComponent().path, &info) == 0 else { return "This disk" }
        let mount = withUnsafeBytes(of: info.f_mntonname) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let name = (try? URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeLocalizedNameKey]))?
            .volumeLocalizedName
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? (mount as NSString).lastPathComponent
    }

    /// Removes an item for good, folders with everything in them. Only the
    /// confirmed delete on a disk without a Trash calls this.
    ///
    /// It works through open folders (`openat`, `unlinkat`) and never follows
    /// a link, so a folder swapped for a link while it runs can't redirect it
    /// elsewhere. It stops at another disk mounted inside, and between items
    /// when cancelled.
    func deletePermanently(_ url: URL) throws {
        let target = try pathGuard.checkModifiable(url)
        let parentPath = target.deletingLastPathComponent().path
        let parent = open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw FileEngineError.posix("Delete", parentPath) }
        defer { close(parent) }
        guard let device = Self.lstatInfo(target.path)?.st_dev else { return }
        try Self.removeTree(Array(target.lastPathComponent.utf8CString), in: parent, device: device, path: target.path)
    }

    private static func removeTree(_ name: [CChar], in parent: Int32, device: dev_t, path: String) throws {
        try Task.checkCancellation()
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw FileEngineError.posix("Delete", path)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            guard unlinkat(parent, name, 0) == 0 else { throw FileEngineError.posix("Delete", path) }
            return
        }
        guard info.st_dev == device else { throw OperationError.diskInside(path) }
        let folder = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw FileEngineError.posix("Delete", path) }
        defer { close(folder) }
        // The folder opened must be the one examined, not something put in its place.
        var opened = stat()
        guard fstat(folder, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            throw FileEngineError.posix("Delete", path, EBUSY)
        }
        for child in try entries(of: folder, path: path) {
            let childName = String(decoding: child.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
            try removeTree(child, in: folder, device: device, path: path + "/" + childName)
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw FileEngineError.posix("Delete", path) }
    }

    /// The names in an open folder, each ending in a zero byte, without "." and "..".
    private static func entries(of folder: Int32, path: String) throws -> [[CChar]] {
        let copy = dup(folder)
        guard copy >= 0 else { throw FileEngineError.posix("Delete", path) }
        guard let stream = fdopendir(copy) else {
            close(copy)
            throw FileEngineError.posix("Delete", path)
        }
        defer { closedir(stream) }
        var names: [[CChar]] = []
        while let entry = readdir(stream) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                bytes.prefix(length).map { CChar(bitPattern: $0) }
            }
            if name == [46] || name == [46, 46] { continue }
            names.append(name + [0])
        }
        return names
    }
}
