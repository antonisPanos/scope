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
        let staging = try pathGuard.checkWriteLocation(
            folder.appendingPathComponent(Self.partialPrefix + UUID().uuidString + "-extract"))
        guard mkdir(staging.path, 0o700) == 0 else { throw FileEngineError.posix("Create folder", staging.path) }

        do {
            let size = Self.lstatInfo(archivePath.path).map { Int64($0.st_size) } ?? 0
            control.update {
                $0.bytesTotal = size
                $0.currentItem = archivePath.lastPathComponent
            }
            try readArchive(archivePath, file: archiveFile, into: staging, quarantine: quarantine, control: control)
            try Task.checkCancellation()

            // One top-level item comes out as itself; several go into a folder
            // named after the archive, as Archive Utility does.
            let names = try FileManager.default.contentsOfDirectory(atPath: staging.path)
            guard !names.isEmpty else { throw OperationError.archive("“\(archivePath.lastPathComponent)” is empty.") }
            let resultSource: URL
            let resultName: String
            if names.count == 1 {
                resultSource = staging.appendingPathComponent(names[0])
                resultName = names[0]
            } else {
                resultSource = staging
                resultName = Self.archiveBaseName(archivePath)
            }
            try Task.checkCancellation()
            let target = try uniqueName(resultName, in: folder, style: .numbered)
            guard Self.renameExclusively(resultSource.path, to: target.path) else {
                throw FileEngineError.posix("Extract", target.path)
            }
            Self.syncFolder(target.deletingLastPathComponent().path)
            undo.add(.trashCreated(target, fileID: Self.fileID(target)))
            if resultSource != staging { Self.removeQuietly(staging.path) }
        } catch {
            Self.removeQuietly(staging.path)
            try Task.checkCancellation()
            throw error
        }
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

    private func readArchive(
        _ archivePath: URL, file: FileHandle, into staging: URL, quarantine: [String: Any]?, control: OperationControl
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
        var compressedEstimate: Int64 = 0
        var metadata: [(relative: String, attributes: [String: Data])] = []
        var directories: [(relative: String, entry: ArchiveEntry)] = []
        var files: [(relative: String, entry: ArchiveEntry)] = []
        var writtenSinceSpaceCheck: Int64 = 0
        let reserve = Self.extractionReserve(at: staging.path)
        // Checked more often than the reserve can fill, so the check, not a
        // failed write, is what normally stops a filling disk.
        let spaceCheckInterval = max(1024 * 1024, min(32 * 1024 * 1024, reserve / 4))
        let diskFull = OperationError.archive(
            "Extracting “\(archivePath.lastPathComponent)” stopped because the disk was almost full. "
                + "Nothing it unpacked was kept.")

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
            let target = staging.appendingPathComponent(relative)
            guard Self.parentIsSafe(relative, under: staging) else {
                // A folder on the way is a link the archive made: writing through it could escape.
                control.skipEntry(name)
                continue
            }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            control.update { $0.currentItem = relative }

            switch entry.kind {
            case .metadata:
                metadata.append((relative, entry.extendedAttributes))
                continue
            case .directory:
                if Self.lstatInfo(target.path) == nil {
                    guard mkdir(target.path, 0o755) == 0 else {
                        throw FileEngineError.posix("Create folder", target.path)
                    }
                }
                directories.append((relative, entry))
                metadata.append((relative, entry.extendedAttributes))
            case .symlink(let link):
                guard !link.isEmpty else { break }
                guard symlink(link, target.path) == 0 else { throw FileEngineError.posix("Create link", target.path) }
            case .hardlink(let linked):
                // A second name for a file extracted earlier: made as a hard
                // link to it, once that file is known to be a plain file
                // inside the staging folder.
                let original = Self.safeRelativePath(linked).map { staging.appendingPathComponent($0) }
                if let original, let relative = Self.safeRelativePath(linked), !relative.isEmpty,
                    Self.parentIsSafe(relative, under: staging),
                    Self.lstatInfo(original.path).map({ $0.st_mode & S_IFMT == S_IFREG }) == true,
                    link(original.path, target.path) == 0
                {
                    control.update { $0.itemsDone += 1 }
                } else {
                    control.skipEntry(name)
                }
                continue
            case .file:
                let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard output >= 0 else { throw FileEngineError.posix("Create", target.path) }
                defer { close(output) }
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
                            let result = write(output, base + written, count - written)
                            if result < 0, errno == EINTR { continue }
                            guard result > 0 else {
                                // Something else may have filled the disk between checks.
                                if errno == ENOSPC || errno == EDQUOT { throw diskFull }
                                throw FileEngineError.posix("Write", target.path)
                            }
                            written += result
                        }
                    }
                    compressedEstimate += Int64(count)
                    writtenSinceSpaceCheck += Int64(count)
                    if writtenSinceSpaceCheck >= spaceCheckInterval {
                        writtenSinceSpaceCheck = 0
                        if let free = Self.freeSpace(at: staging.path), free < reserve { throw diskFull }
                    }
                    let done = compressedEstimate
                    control.update { $0.bytesDone = min($0.bytesTotal, done / 2) }
                }
                // Set quarantine before restrictive modes, and before the
                // completed result becomes visible under its final name.
                try ArchiveAttributes.apply(entry.extendedAttributes, to: output)
                try applyQuarantine(quarantine, to: target)
                // Some formats deliver sidecars after data. Keep the private
                // staging file writable until all metadata has arrived.
                files.append((relative, entry))
                // Like copies, extracted files are on disk before they're shown.
                guard fsync(output) == 0 else { throw FileEngineError.posix("Write", target.path) }
            case .other:
                // Devices, pipes and sockets are not extracted.
                control.skipEntry(name)
            }
            control.update { $0.itemsDone += 1 }
        }
        // Mark every folder while staging permissions still allow descent.
        try quarantineFolders(in: staging, properties: quarantine)
        try restoreArchiveMetadata(metadata, files: files, directories: directories, under: staging)
        control.update { $0.bytesDone = $0.bytesTotal }
    }

    /// Includes the staging root (which may itself be the final result),
    /// implicit parents, and app bundle roots. Never follows an archive link.
    private func quarantineFolders(in staging: URL, properties: [String: Any]?) throws {
        guard properties != nil else { return }
        try applyQuarantine(properties, to: staging)
        guard let enumerator = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: nil) else {
            throw FileEngineError.posix("Read extracted folders", staging.path)
        }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard let info = Self.lstatInfo(url.path) else { throw FileEngineError.posix("Read", url.path) }
            if info.st_mode & S_IFMT == S_IFDIR { try applyQuarantine(properties, to: url) }
        }
    }

    private func restoreArchiveMetadata(
        _ metadata: [(relative: String, attributes: [String: Data])],
        files: [(relative: String, entry: ArchiveEntry)],
        directories: [(relative: String, entry: ArchiveEntry)], under staging: URL
    ) throws {
        // AppleDouble records may precede or follow their data entry. They
        // can describe only an existing regular file/directory in staging.
        for record in metadata {
            try Task.checkCancellation()
            guard Self.parentIsSafe(record.relative, under: staging) else { throw AppleDouble.invalid() }
            let target = try pathGuard.checkWriteLocation(staging.appendingPathComponent(record.relative))
            guard let info = Self.lstatInfo(target.path),
                info.st_mode & S_IFMT == S_IFDIR || info.st_mode & S_IFMT == S_IFREG
            else { throw AppleDouble.invalid() }
            let descriptor = open(target.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw FileEngineError.posix("Restore archive metadata", target.path) }
            defer { close(descriptor) }
            try ArchiveAttributes.apply(record.attributes, to: descriptor)
        }
        // Restore file modes only after late AppleDouble attributes; restore
        // directories deepest first after every child has been written.
        for record in files + directories.sorted(by: { $0.relative.count > $1.relative.count }) {
            try Task.checkCancellation()
            let target = try pathGuard.checkWriteLocation(staging.appendingPathComponent(record.relative))
            let directory = record.entry.kind == .directory
            let descriptor = open(target.path, O_RDONLY | (directory ? O_DIRECTORY : 0) | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard descriptor >= 0 else { throw FileEngineError.posix("Restore folder metadata", target.path) }
            defer { close(descriptor) }
            let permissions = record.entry.permissions.map { mode_t($0 & 0o777) } ?? (directory ? 0o755 : 0o644)
            guard fchmod(descriptor, permissions) == 0 else {
                throw FileEngineError.posix("Restore folder permissions", target.path)
            }
            var times = [
                timespec(tv_sec: Int(record.entry.modified), tv_nsec: 0),
                timespec(tv_sec: Int(record.entry.modified), tv_nsec: 0),
            ]
            guard futimens(descriptor, &times) == 0 else {
                throw FileEngineError.posix("Restore folder dates", target.path)
            }
            _ = fsync(descriptor)
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

    /// Whether every folder between `root` and the entry is a real folder (or
    /// missing), never a symlink an earlier entry created.
    static func parentIsSafe(_ relative: String, under root: URL) -> Bool {
        var current = root
        for component in relative.split(separator: "/").dropLast() {
            current = current.appendingPathComponent(String(component))
            guard let info = lstatInfo(current.path) else { return true }
            if info.st_mode & S_IFMT != S_IFDIR { return false }
        }
        return true
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
