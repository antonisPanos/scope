import Foundation
import os

/// Compress and extract through libarchive, the library macOS's own tar and
/// ditto use. Both write under a hidden partial name and move the result into
/// place only at the end, so cancelling leaves nothing behind.
extension FileEngine {
    private static let archiveLogger = Logger(subsystem: "com.antonispanos.scope", category: "Archives")
    /// Extensions Scope offers to extract.
    public static let archiveExtensions: Set<String> = [
        "zip", "tar", "tgz", "tbz", "tbz2", "txz", "gz", "bz2", "xz", "7z", "rar",
    ]

    public static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return archiveExtensions.contains(url.pathExtension.lowercased())
            || name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tar.xz")
    }

    // MARK: - Extract

    /// Space an extraction always leaves free on the disk: 512 MB, or a
    /// twentieth of a smaller disk. It stops, and removes what it wrote,
    /// rather than go below this.
    static func extractionReserve(at path: String) -> Int64 {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return 512 * 1024 * 1024 }
        return min(512 * 1024 * 1024, Int64(info.f_blocks) * Int64(info.f_bsize) / 20)
    }

    /// Why an archive can't be extracted next to itself, when its unpacked
    /// size is known up front and wouldn't fit on the disk; nil when it fits
    /// or the size isn't known until extracting (the extraction then stops by
    /// itself if the disk gets full). For the UI to warn before starting.
    public func extractionSpaceProblem(_ archiveURL: URL) async -> String? {
        return await onIOThreads {
            guard !Task.isCancelled, let archive = try? pathGuard.checkLocation(archiveURL),
                let needed = declaredUnpackedSize(archive),
                let free = Self.freeSpace(at: archive.deletingLastPathComponent().path),
                needed > free - Self.extractionReserve(at: archive.deletingLastPathComponent().path)
            else {
                return nil
            }
            let size = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return "“\(archive.lastPathComponent)” unpacks to \(size(needed)), "
                + "but only \(size(max(0, free))) is free on this disk."
        }
    }

    /// Free space on the disk holding `path`, for this user.
    static func freeSpace(at path: String) -> Int64? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// Free space on the disk holding an open item, for this user.
    static func freeSpace(of descriptor: CopyDescriptor) -> Int64? {
        var info = statfs()
        guard fstatfs(descriptor.raw, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// The total size of an archive's entries, for formats that record it in
    /// their headers and can be read through quickly without unpacking (zip,
    /// 7z, uncompressed tar). Nil for compressed streams or unknown sizes.
    /// Impossible declarations saturate at Int64.max so preflight refuses
    /// them instead of treating an overflow or negative size as unknown.
    func declaredUnpackedSize(_ archive: URL) -> Int64? {
        guard !Task.isCancelled, ["zip", "7z", "tar"].contains(archive.pathExtension.lowercased()),
            let file = Self.openForReading(archive),
            let reader = try? archiveReaders.open(file, singleFile: false)
        else {
            return nil
        }
        var total: Int64 = 0
        do {
            while !Task.isCancelled, let entry = try reader.nextEntry() {
                guard let size = entry.size else { return nil }
                guard size >= 0 else { return .max }
                let (sum, overflow) = total.addingReportingOverflow(size)
                guard !overflow else { return .max }
                total = sum
            }
            return Task.isCancelled ? nil : total
        } catch {
            return nil
        }
    }

    /// The archive, opened read-only without following a link at its own name.
    static func openForReading(_ archive: URL) -> FileHandle? {
        let descriptor = open(archive.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func extract(_ archiveURL: URL, control: OperationControl, undo: UndoRecorder) async throws {
        try Task.checkCancellation()
        if let problem = await extractionSpaceProblem(archiveURL) { throw OperationError.archive(problem) }
        try Task.checkCancellation()
        let archivePath = try pathGuard.checkLocation(archiveURL)
        guard let archiveFile = Self.openForReading(archivePath) else {
            throw FileEngineError.posix("Open", archivePath.path)
        }
        // Only the archive we opened supplies quarantine provenance. Entry
        // metadata from the parser must never be able to remove it.
        let quarantine = try archivePath.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        let folder = archivePath.deletingLastPathComponent()
        let stagingURL = try pathGuard.checkWriteLocation(
            folder.appendingPathComponent(Self.partialPrefix + UUID().uuidString + "-extract"))
        // The archive's folder is pinned once, after the guard. Everything is
        // written through descriptors from here, and published only into it.
        let staging = try CopyLocation(checked: stagingURL)
        guard mkdirat(staging.parent.raw, staging.name, 0o700) == 0 else {
            throw FileEngineError.posix("Create folder", stagingURL.path)
        }
        var stagingIdentity: stat?

        do {
            let created = try staging.info()
            stagingIdentity = created
            let tree = ExtractionTree(
                root: try staging.open(O_RDONLY | O_DIRECTORY, matching: created), path: stagingURL.path)
            try tree.prepareQuarantine(quarantine, at: stagingURL, pathGuard: pathGuard)
            let size = Self.lstatInfo(archivePath.path).map { Int64($0.st_size) } ?? 0
            control.update {
                $0.bytesTotal = size
                $0.currentItem = archivePath.lastPathComponent
            }
            try readArchive(archivePath, file: archiveFile, into: tree, control: control)
            try Task.checkCancellation()

            // One top-level item comes out as itself; several go into a folder
            // named after the archive, as Archive Utility does.
            let names = try CopyLocation.names(in: tree.root, path: tree.path)
            guard !names.isEmpty else { throw OperationError.archive("“\(archivePath.lastPathComponent)” is empty.") }
            let single = names.count == 1
            let resultName = single ? names[0] : Self.archiveBaseName(archivePath)
            try Task.checkCancellation()
            let target = try uniqueName(resultName, in: folder, style: .numbered)
            guard target.deletingLastPathComponent().path == folder.path else {
                throw Self.archiveFolderChanged(folder.path)
            }
            // The folder the staging name is in must still be the one pinned.
            try staging.validateParent(pathGuard: pathGuard)
            let published: Bool
            if single {
                let item = CopyLocation(parent: tree.root, name: names[0], path: tree.path + "/" + names[0])
                let isFolder = try item.info().st_mode & S_IFMT == S_IFDIR
                published = item.renameExclusively(
                    into: staging.parent, as: target.lastPathComponent, isDirectory: isFolder)
            } else {
                guard CopyLocation.same(try staging.info(), created) else { throw ExtractionTree.changed(tree.path) }
                published = staging.renameExclusively(to: target.lastPathComponent, isDirectory: true)
            }
            guard published else { throw FileEngineError.posix("Extract", target.path) }
            staging.syncParent()
            undo.add(.trashCreated(target, fileID: Self.fileID(target)))
            if single { Self.removeStaging(staging, matching: created) }
        } catch {
            Self.removeStaging(staging, matching: stagingIdentity)
            try Task.checkCancellation()
            throw error
        }
    }

    /// Removes the staging folder through its pinned parent. A replaced
    /// staging name is left alone rather than followed.
    private static func removeStaging(_ staging: CopyLocation, matching identity: stat?) {
        do {
            try staging.removePartial(matching: identity)
        } catch {
            archiveLogger.fault("Could not remove extraction staging: \(error.localizedDescription)")
        }
    }

    private static func archiveFolderChanged(_ path: String) -> FileEngineError {
        .posix("Archive folder changed while extracting", path, EBUSY)
    }

    /// "photos.tar.gz" becomes "photos".
    static func archiveBaseName(_ url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        name = (name as NSString).deletingPathExtension
        return name.isEmpty ? "Archive" : name
    }

    /// A file or folder whose final permissions and dates are set once every
    /// entry is in. Only these small fields are kept, never its attributes.
    private struct Finalize {
        let relative: String
        let identity: stat
        let permissions: UInt16?
        let modified: Int64
    }

    private func readArchive(
        _ archivePath: URL, file: FileHandle, into tree: ExtractionTree, control: OperationControl
    ) throws {
        // A bare .gz or .xz holds one compressed file without an archive around it.
        let isBareCompressed =
            ["gz", "bz2", "xz"].contains(archivePath.pathExtension.lowercased())
            && !archivePath.deletingPathExtension().pathExtension.lowercased().hasPrefix("tar")
        let reader: any ArchiveReading
        do {
            reader = try archiveReaders.open(file, singleFile: isBareCompressed)
        } catch {
            throw OperationError.notAnArchive(archivePath.path)
        }
        func damaged(_ error: ArchiveReadError) -> OperationError {
            if case .damaged(let message) = error { return .archive(message) }
            return .notAnArchive(archivePath.path)
        }
        let limits = extractionLimits
        var compressedEstimate: Int64 = 0
        // Metadata sidecars whose file or folder hasn't arrived yet; every
        // other sidecar is applied as it arrives and then dropped (#149).
        var pending: [String: [String: Data]] = [:]
        var pendingBytes = 0
        var finalize: [Finalize] = []
        var writtenSinceSpaceCheck: Int64 = 0
        let reserve = Self.extractionReserve(at: tree.path)
        // Checked more often than the reserve can fill, so the check, not a
        // failed write, is what normally stops a filling disk.
        let spaceCheckInterval = max(1024 * 1024, min(32 * 1024 * 1024, reserve / 4))
        let diskFull = OperationError.archive(
            "Extracting “\(archivePath.lastPathComponent)” stopped because the disk was almost full. "
                + "Nothing it unpacked was kept.")
        func wrote(_ bytes: Int) throws {
            writtenSinceSpaceCheck += Int64(bytes)
            if writtenSinceSpaceCheck >= spaceCheckInterval {
                writtenSinceSpaceCheck = 0
                if let free = Self.freeSpace(of: tree.root), free < reserve { throw diskFull }
            }
        }
        func remember(_ relative: String, _ identity: stat, _ entry: ArchiveEntry) throws {
            guard finalize.count < limits.entries else {
                throw OperationError.archive(
                    "“\(archivePath.lastPathComponent)” has more than \(limits.entries) items, "
                        + "more than Scope extracts at once. Nothing it unpacked was kept.")
            }
            finalize.append(
                Finalize(
                    relative: relative, identity: identity, permissions: entry.permissions, modified: entry.modified))
        }
        // Applies attributes through an open descriptor; resource forks are
        // written to disk too, so they count against the space reserve.
        func apply(_ attributes: [String: Data], to descriptor: CopyDescriptor) throws {
            guard !attributes.isEmpty else { return }
            try ArchiveAttributes.apply(attributes, to: descriptor.raw)
            try wrote(attributes.values.reduce(0) { $0 + $1.count })
        }
        func applyPending(_ relative: String, to descriptor: CopyDescriptor) throws {
            guard let attributes = pending.removeValue(forKey: relative) else { return }
            pendingBytes -= Self.byteCount(attributes)
            try apply(attributes, to: descriptor)
        }

        while true {
            try Task.checkCancellation()
            try control.waitWhilePaused()
            let next: ArchiveEntry?
            do {
                next = try reader.nextEntry()
            } catch {
                throw damaged(error)
            }
            guard let entry = next else { break }
            var name = entry.name
            if isBareCompressed { name = (archivePath.lastPathComponent as NSString).deletingPathExtension }

            guard let relative = Self.safeRelativePath(name) else {
                control.skipEntry(name)
                continue
            }
            if relative.isEmpty { continue }
            try ArchiveAttributes.validate(entry.extendedAttributes)
            guard case .place(let place) = try tree.locate(relative, creating: true) else {
                // A folder on the way is a link the archive made: writing through it could escape.
                control.skipEntry(name)
                continue
            }
            control.update { $0.currentItem = relative }

            switch entry.kind {
            case .metadata:
                // AppleDouble records may precede or follow their data entry,
                // and can describe only a regular file or folder in staging.
                if let existing = try tree.info(place) {
                    let kind = existing.st_mode & S_IFMT
                    guard kind == S_IFREG || kind == S_IFDIR else { throw AppleDouble.invalid() }
                    try apply(entry.extendedAttributes, to: tree.open(place, matching: existing))
                } else if !entry.extendedAttributes.isEmpty {
                    let earlier = pending[relative] ?? [:]
                    let merged = earlier.merging(entry.extendedAttributes) { _, later in later }
                    pendingBytes += Self.byteCount(merged) - Self.byteCount(earlier)
                    guard pendingBytes <= limits.pendingMetadataBytes, merged.count <= 4096 else {
                        throw OperationError.archive(
                            "“\(archivePath.lastPathComponent)” has more macOS metadata waiting for its files "
                                + "than Scope can hold. Nothing it unpacked was kept.")
                    }
                    pending[relative] = merged
                }
                continue
            case .directory:
                let existing = try tree.info(place)
                if let existing, existing.st_mode & S_IFMT != S_IFDIR {
                    control.skipEntry(name)
                    continue
                }
                if existing == nil {
                    guard mkdirat(place.folder.raw, place.name, 0o755) == 0 else {
                        throw FileEngineError.posix("Create folder", place.path)
                    }
                }
                guard let made = try tree.info(place) else { throw ExtractionTree.changed(place.path) }
                let directory = try tree.open(place, matching: made)
                if existing == nil { try tree.markQuarantined(directory) }
                try apply(entry.extendedAttributes, to: directory)
                try applyPending(relative, to: directory)
                try remember(relative, made, entry)
            case .symlink(let link):
                guard !link.isEmpty else { break }
                guard symlinkat(link, place.folder.raw, place.name) == 0 else {
                    throw FileEngineError.posix("Create link", place.path)
                }
            case .hardlink(let linked):
                // A second name for a file extracted earlier: made as a hard
                // link to it, once that file is known to be a plain file
                // inside the staging folder.
                if let original = Self.safeRelativePath(linked), !original.isEmpty,
                    case .place(let source) = try tree.locate(original, creating: false),
                    try tree.info(source).map({ $0.st_mode & S_IFMT == S_IFREG }) == true,
                    linkat(source.folder.raw, source.name, place.folder.raw, place.name, 0) == 0
                {
                    control.update { $0.itemsDone += 1 }
                } else {
                    control.skipEntry(name)
                }
                continue
            case .file:
                let output = try CopyDescriptor(
                    openat(place.folder.raw, place.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600),
                    path: place.path)
                while true {
                    try Task.checkCancellation()
                    try control.waitWhilePaused()
                    let data: Data
                    do {
                        data = try reader.readData(upTo: FileEngine.chunkSize)
                    } catch {
                        throw damaged(error)
                    }
                    if data.isEmpty { break }
                    let count = data.count
                    try data.withUnsafeBytes { bytes in
                        guard let base = bytes.baseAddress else { return }
                        var written = 0
                        while written < count {
                            let result = write(output.raw, base + written, count - written)
                            if result < 0, errno == EINTR { continue }
                            guard result > 0 else {
                                // Something else may have filled the disk between checks.
                                if errno == ENOSPC || errno == EDQUOT { throw diskFull }
                                throw FileEngineError.posix("Write", place.path)
                            }
                            written += result
                        }
                    }
                    compressedEstimate += Int64(count)
                    try wrote(count)
                    let done = compressedEstimate
                    control.update { $0.bytesDone = min($0.bytesTotal, done / 2) }
                }
                // Set quarantine before restrictive modes, and before the
                // completed result becomes visible under its final name.
                try apply(entry.extendedAttributes, to: output)
                try tree.markQuarantined(output)
                try applyPending(relative, to: output)
                // Some formats deliver sidecars after data. Keep the private
                // staging file writable until all metadata has arrived.
                try remember(relative, try output.info(), entry)
                // Like copies, extracted files are on disk before they're shown.
                guard fsync(output.raw) == 0 else { throw FileEngineError.posix("Write", place.path) }
            case .other:
                // Devices, pipes and sockets are not extracted.
                control.skipEntry(name)
            }
            control.update { $0.itemsDone += 1 }
        }
        // Sidecars for folders made only as parents of other entries.
        for (relative, attributes) in pending.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            guard case .place(let place) = try tree.locate(relative, creating: false),
                let existing = try tree.info(place),
                existing.st_mode & S_IFMT == S_IFDIR || existing.st_mode & S_IFMT == S_IFREG
            else { throw AppleDouble.invalid() }
            try apply(attributes, to: tree.open(place, matching: existing))
        }
        pending = [:]
        try restoreModesAndDates(finalize, in: tree)
        control.update { $0.bytesDone = $0.bytesTotal }
    }

    private static func byteCount(_ attributes: [String: Data]) -> Int {
        attributes.reduce(0) { $0 + $1.key.utf8.count + $1.value.count }
    }

    /// Restores file modes only after late AppleDouble attributes, and
    /// folders deepest first after every child has been written.
    private func restoreModesAndDates(_ records: [Finalize], in tree: ExtractionTree) throws {
        let files = records.filter { $0.identity.st_mode & S_IFMT != S_IFDIR }
        let folders = records.filter { $0.identity.st_mode & S_IFMT == S_IFDIR }
            .sorted { $0.relative.count > $1.relative.count }
        for record in files + folders {
            try Task.checkCancellation()
            let descriptor = try tree.reopen(record.relative, matching: record.identity)
            let directory = record.identity.st_mode & S_IFMT == S_IFDIR
            let permissions = record.permissions.map { mode_t($0 & 0o777) } ?? (directory ? 0o755 : 0o644)
            guard fchmod(descriptor.raw, permissions) == 0 else {
                throw FileEngineError.posix("Restore permissions", tree.path + "/" + record.relative)
            }
            var times = [
                timespec(tv_sec: Int(record.modified), tv_nsec: 0),
                timespec(tv_sec: Int(record.modified), tv_nsec: 0),
            ]
            guard futimens(descriptor.raw, &times) == 0 else {
                throw FileEngineError.posix("Restore dates", tree.path + "/" + record.relative)
            }
            _ = fsync(descriptor.raw)
        }
    }

    private func applyQuarantine(_ properties: [String: Any]?, to url: URL) throws {
        guard let properties else { return }
        var target = try pathGuard.checkWriteLocation(url)
        var values = URLResourceValues()
        // Use the public Launch Services-backed property instead of copying
        // undocumented raw flags or granting approval to extracted code.
        values.quarantineProperties = properties
        try target.setResourceValues(values)
    }

    /// The entry's path made relative and checked: absolute paths and any
    /// ".." component are refused (nil), so nothing lands outside the folder.
    static func safeRelativePath(_ name: String) -> String? {
        if name.hasPrefix("/") || name.hasPrefix("~") { return nil }
        let components = name.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        if components.contains("..") { return nil }
        return components.joined(separator: "/")
    }

    // MARK: - Compress

    func compress(_ items: [URL], format: ArchiveFormat, control: OperationControl, undo: UndoRecorder) async throws {
        let sources = try items.map { try pathGuard.checkLocation($0) }
        guard let first = sources.first else { return }
        let folder = first.deletingLastPathComponent()
        let baseName = sources.count == 1 ? first.lastPathComponent : "Archive"
        let target = try uniqueName("\(baseName).\(format.fileExtension)", in: folder, style: .numbered)
        let partial = try pathGuard.checkWriteLocation(
            folder.appendingPathComponent(Self.partialPrefix + UUID().uuidString + "." + format.fileExtension))
        let totals = try measure(sources)
        control.update {
            $0.bytesTotal = totals.bytes
            $0.itemsTotal = totals.items
        }

        let destination = try CopyLocation(checked: pathGuard.checkWriteLocation(target))
        let staged = CopyLocation(parent: destination.parent, name: partial.lastPathComponent, path: partial.path)
        let descriptor = openat(
            staged.parent.raw, staged.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw FileEngineError.posix("Create archive", partial.path) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        var identity = stat()
        guard fstat(descriptor, &identity) == 0 else {
            throw FileEngineError.posix("Read archive descriptor", partial.path)
        }
        let budget = ArchiveWriteBudget()
        let fault = writeFault
        do {
            let writer = try archiveWriters.open(format: format, control: control) {
                (data: Data) throws(ArchiveWriteError) in
                do {
                    try Task.checkCancellation()
                    try control.waitWhilePaused()
                    guard data.count <= Self.chunkSize else {
                        throw ArchiveWriteError.failed("Archive output chunk is too large.")
                    }
                    let offset = budget.written
                    if let code = fault?(partial.path, offset) {
                        throw FileEngineError.posix("Write archive", partial.path, code)
                    }
                    try budget.accept(data.count, descriptor: output.fileDescriptor)
                    try output.write(contentsOf: data)
                } catch {
                    throw .failed(error.localizedDescription)
                }
            }
            defer { writer.cancel() }
            var job = CompressionJob(writer: writer, format: format, control: control, budget: budget)
            for source in sources { try job.add(CopyLocation(checked: source), as: source.lastPathComponent) }
            try writer.finish()
            try Task.checkCancellation()
            try control.waitWhilePaused()
            guard budget.written > 0 else {
                throw OperationError.archive("The archive writer returned no data.")
            }
            try destination.validateParent(pathGuard: pathGuard)
            guard CopyLocation.same(try staged.info(), identity) else {
                throw FileEngineError.posix("Archive partial changed", partial.path, EBUSY)
            }
            try applyQuarantine(job.quarantine, to: partial)
            try output.synchronize()
            try destination.validateParent(pathGuard: pathGuard)
            guard CopyLocation.same(try staged.info(), identity),
                staged.renameExclusively(to: destination.name, isDirectory: false)
            else {
                throw FileEngineError.posix("Compress", target.path)
            }
            destination.syncParent()
            undo.add(.trashCreated(target, fileID: Self.fileID(target)))
        } catch {
            do { try staged.removePartial(matching: identity) } catch {
                Self.archiveLogger.fault("Could not remove archive partial: \(error.localizedDescription)")
            }
            try Task.checkCancellation()
            if let error = error as? ArchiveWriteError { throw OperationError.archive(error.localizedDescription) }
            throw error
        }
    }
}
