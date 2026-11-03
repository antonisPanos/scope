import Foundation

/// One extraction's writing side: it creates each entry in the pinned tree,
/// applies metadata as it arrives, and remembers only what is needed to set
/// final modes and dates (#145, #149). The archive reader stays outside.
final class ExtractionSession {
    let tree: ExtractionTree
    let control: OperationControl
    private let limits: ExtractionLimits
    private let archiveName: String
    private let reserve: Int64
    private let spaceCheckInterval: Int64
    private var writtenSinceSpaceCheck: Int64 = 0
    private var compressedEstimate: Int64 = 0
    /// Sidecars whose file or folder hasn't arrived yet. Every other sidecar
    /// is applied as it arrives and then dropped.
    private var pending: [String: [String: Data]] = [:]
    private var pendingBytes = 0
    private var finalize: [Finalize] = []

    /// A file or folder whose final permissions and dates are set once every
    /// entry is in. Only these small fields are kept, never its attributes.
    private struct Finalize {
        let relative: String
        let identity: stat
        let permissions: UInt16?
        let modified: Int64
    }

    init(tree: ExtractionTree, control: OperationControl, limits: ExtractionLimits, archiveName: String) {
        self.tree = tree
        self.control = control
        self.limits = limits
        self.archiveName = archiveName
        reserve = FileEngine.extractionReserve(at: tree.path)
        // Checked more often than the reserve can fill, so the check, not a
        // failed write, is what normally stops a filling disk.
        spaceCheckInterval = max(1024 * 1024, min(32 * 1024 * 1024, reserve / 4))
    }

    var diskFull: OperationError {
        .archive(
            "Extracting “\(archiveName)” stopped because the disk was almost full. Nothing it unpacked was kept.")
    }

    // MARK: - Entries

    /// Applies a sidecar now if its file or folder exists, or holds it
    /// within the budget until that arrives. Only a regular file or folder
    /// may be described. Attributes apply in arrival order, so the latest
    /// sidecar wins: one held for a folder that a later entry made as its
    /// parent goes first (#160).
    func metadata(_ attributes: [String: Data], at place: ExtractionTree.Place, relative: String) throws {
        if let existing = try tree.info(place) {
            let kind = existing.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else { throw AppleDouble.invalid() }
            let descriptor = try tree.open(place, matching: existing)
            try applyPending(relative, to: descriptor)
            try apply(attributes, to: descriptor)
            return
        }
        guard !attributes.isEmpty else { return }
        let earlier = pending[relative] ?? [:]
        let merged = earlier.merging(attributes) { _, later in later }
        pendingBytes += Self.byteCount(merged) - Self.byteCount(earlier)
        guard pendingBytes <= limits.pendingMetadataBytes, merged.count <= 4096 else {
            throw OperationError.archive(
                "“\(archiveName)” has more macOS metadata waiting for its files than Scope can hold. "
                    + "Nothing it unpacked was kept.")
        }
        pending[relative] = merged
    }

    /// False when something other than a folder already has the name.
    func directory(_ entry: ArchiveEntry, at place: ExtractionTree.Place, relative: String) throws -> Bool {
        let existing = try tree.info(place)
        if let existing, existing.st_mode & S_IFMT != S_IFDIR { return false }
        if existing == nil {
            guard mkdirat(place.folder.raw, place.name, 0o755) == 0 else {
                throw FileEngineError.posix("Create folder", place.path)
            }
        }
        guard let made = try tree.info(place) else { throw ExtractionTree.changed(place.path) }
        let directory = try tree.open(place, matching: made)
        // Sidecars held for it arrived before this entry, so its own
        // attributes come after them.
        try applyPending(relative, to: directory)
        try apply(entry.extendedAttributes, to: directory)
        if existing == nil { try tree.markQuarantined(directory) }
        try remember(relative, made, entry)
        return true
    }

    func symlink(_ target: String, at place: ExtractionTree.Place) throws {
        guard symlinkat(target, place.folder.raw, place.name) == 0 else {
            throw FileEngineError.posix("Create link", place.path)
        }
    }

    /// A second name for a file extracted earlier: made as a hard link to it,
    /// once that file is known to be a plain file inside the staging folder.
    func hardLink(to linked: String, at place: ExtractionTree.Place) throws -> Bool {
        guard let original = FileEngine.safeRelativePath(linked), !original.isEmpty,
            case .place(let source) = try tree.locate(original, creating: false),
            try tree.info(source).map({ $0.st_mode & S_IFMT == S_IFREG }) == true
        else { return false }
        return linkat(source.folder.raw, source.name, place.folder.raw, place.name, 0) == 0
    }

    /// Writes a file's data as `read` delivers it, until an empty chunk.
    func file(
        _ entry: ArchiveEntry, at place: ExtractionTree.Place, relative: String, read: () throws -> Data
    ) throws {
        let output = try CopyDescriptor(
            openat(place.folder.raw, place.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600),
            path: place.path)
        while true {
            try Task.checkCancellation()
            try control.waitWhilePaused()
            let data = try read()
            if data.isEmpty { break }
            try write(data, to: output, path: place.path)
            compressedEstimate += Int64(data.count)
            try wrote(data.count)
            let done = compressedEstimate
            control.update { $0.bytesDone = min($0.bytesTotal, done / 2) }
        }
        // Earlier sidecars first, then the entry's own attributes. Set
        // quarantine before restrictive modes, and before the completed
        // result becomes visible under its final name.
        try applyPending(relative, to: output)
        try apply(entry.extendedAttributes, to: output)
        try tree.markQuarantined(output)
        // Some formats deliver sidecars after data. Keep the private staging
        // file writable until all metadata has arrived.
        try remember(relative, try output.info(), entry)
        // Like copies, extracted files are on disk before they're shown.
        guard fsync(output.raw) == 0 else { throw FileEngineError.posix("Write", place.path) }
    }

    private func write(_ data: Data, to output: CopyDescriptor, path: String) throws {
        let count = data.count
        let diskFull = diskFull
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < count {
                let result = Darwin.write(output.raw, base + written, count - written)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    // Something else may have filled the disk between checks.
                    if errno == ENOSPC || errno == EDQUOT { throw diskFull }
                    throw FileEngineError.posix("Write", path)
                }
                written += result
            }
        }
    }

    // MARK: - The end

    /// Applies sidecars for folders made only as parents of other entries,
    /// then sets modes and dates: files after every late sidecar, folders
    /// deepest first after every child has been written.
    func finish() throws {
        for (relative, attributes) in pending.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            guard case .place(let place) = try tree.locate(relative, creating: false),
                let existing = try tree.info(place),
                existing.st_mode & S_IFMT == S_IFDIR || existing.st_mode & S_IFMT == S_IFREG
            else { throw AppleDouble.invalid() }
            try apply(attributes, to: tree.open(place, matching: existing))
        }
        pending = [:]
        pendingBytes = 0
        let files = finalize.filter { $0.identity.st_mode & S_IFMT != S_IFDIR }
        let folders = finalize.filter { $0.identity.st_mode & S_IFMT == S_IFDIR }
            .sorted { $0.relative.count > $1.relative.count }
        for record in files + folders {
            try Task.checkCancellation()
            try restore(record)
        }
    }

    private func restore(_ record: Finalize) throws {
        let descriptor = try tree.reopen(record.relative, matching: record.identity)
        let directory = record.identity.st_mode & S_IFMT == S_IFDIR
        let path = tree.path + "/" + record.relative
        let permissions = record.permissions.map { mode_t($0 & 0o777) } ?? (directory ? 0o755 : 0o644)
        guard fchmod(descriptor.raw, permissions) == 0 else { throw FileEngineError.posix("Restore permissions", path) }
        var times = [
            timespec(tv_sec: Int(record.modified), tv_nsec: 0),
            timespec(tv_sec: Int(record.modified), tv_nsec: 0),
        ]
        guard futimens(descriptor.raw, &times) == 0 else { throw FileEngineError.posix("Restore dates", path) }
        _ = fsync(descriptor.raw)
    }

    // MARK: - Helpers

    /// Disk writes, including attributes (resource forks are data too),
    /// counted against the space reserve.
    private func wrote(_ bytes: Int) throws {
        writtenSinceSpaceCheck += Int64(bytes)
        guard writtenSinceSpaceCheck >= spaceCheckInterval else { return }
        writtenSinceSpaceCheck = 0
        if let free = FileEngine.freeSpace(of: tree.root), free < reserve { throw diskFull }
    }

    private func remember(_ relative: String, _ identity: stat, _ entry: ArchiveEntry) throws {
        guard finalize.count < limits.entries else {
            throw OperationError.archive(
                "“\(archiveName)” has more than \(limits.entries) items, more than Scope extracts at once. "
                    + "Nothing it unpacked was kept.")
        }
        finalize.append(
            Finalize(relative: relative, identity: identity, permissions: entry.permissions, modified: entry.modified))
    }

    private func apply(_ attributes: [String: Data], to descriptor: CopyDescriptor) throws {
        guard !attributes.isEmpty else { return }
        try ArchiveAttributes.apply(attributes, to: descriptor.raw)
        try wrote(attributes.values.reduce(0) { $0 + $1.count })
    }

    private func applyPending(_ relative: String, to descriptor: CopyDescriptor) throws {
        guard let attributes = pending.removeValue(forKey: relative) else { return }
        pendingBytes -= Self.byteCount(attributes)
        try apply(attributes, to: descriptor)
    }

    private static func byteCount(_ attributes: [String: Data]) -> Int {
        attributes.reduce(0) { $0 + $1.key.utf8.count + $1.value.count }
    }
}
