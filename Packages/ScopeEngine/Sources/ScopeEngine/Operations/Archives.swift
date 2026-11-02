import CArchive
import Foundation

/// Compress and extract through libarchive, the library macOS's own tar and
/// ditto use. Both write under a hidden partial name and move the result into
/// place only at the end, so cancelling leaves nothing behind.
extension FileEngine {
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
        guard let archive = try? pathGuard.checkLocation(archiveURL),
            let needed = Self.declaredUnpackedSize(archive),
            let free = Self.freeSpace(at: archive.deletingLastPathComponent().path),
            needed > free - Self.extractionReserve(at: archive.deletingLastPathComponent().path)
        else {
            return nil
        }
        let size = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return "“\(archive.lastPathComponent)” unpacks to \(size(needed)), "
            + "but only \(size(max(0, free))) is free on this disk."
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
    static func declaredUnpackedSize(_ archive: URL) -> Int64? {
        guard ["zip", "7z", "tar"].contains(archive.pathExtension.lowercased()), let reader = archive_read_new() else {
            return nil
        }
        defer { archive_read_free(reader) }
        archive_read_support_filter_all(reader)
        archive_read_support_format_all(reader)
        guard archive_read_open_filename(reader, archive.path, 64 * 1024) == ARCHIVE_OK else { return nil }
        var total: Int64 = 0
        var entry: OpaquePointer?
        while true {
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { return total }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let entry, archive_entry_size_is_set(entry) != 0
            else {
                return nil
            }
            total += max(0, archive_entry_size(entry))
            archive_read_data_skip(reader)
        }
    }

    func extract(_ archiveURL: URL, control: OperationControl, undo: UndoRecorder) async throws {
        if let problem = await extractionSpaceProblem(archiveURL) { throw OperationError.archive(problem) }
        let archivePath = try pathGuard.checkLocation(archiveURL)
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
            try readArchive(archivePath, into: staging, control: control)

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
            let target = try uniqueName(resultName, in: folder, style: .numbered)
            guard renamex_np(resultSource.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                throw FileEngineError.posix("Extract", target.path)
            }
            Self.syncFolder(target.deletingLastPathComponent().path)
            undo.add(.trashCreated(target, fileID: Self.fileID(target)))
            if resultSource != staging { Self.removeQuietly(staging.path) }
        } catch {
            Self.removeQuietly(staging.path)
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

    private func readArchive(_ archivePath: URL, into staging: URL, control: OperationControl) throws {
        guard let reader = archive_read_new() else {
            throw OperationError.archive("Couldn't start reading the archive.")
        }
        defer { archive_read_free(reader) }
        archive_read_support_filter_all(reader)
        archive_read_support_format_all(reader)
        // A bare .gz or .xz holds one compressed file without an archive around it.
        let isBareCompressed =
            ["gz", "bz2", "xz"].contains(archivePath.pathExtension.lowercased())
            && !archivePath.deletingPathExtension().pathExtension.lowercased().hasPrefix("tar")
        if isBareCompressed { archive_read_support_format_raw(reader) }

        guard archive_read_open_filename(reader, archivePath.path, 64 * 1024) == ARCHIVE_OK else {
            throw OperationError.notAnArchive(archivePath.path)
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: FileEngine.chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        var entry: OpaquePointer?
        var compressedEstimate: Int64 = 0
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
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let entry else {
                throw OperationError.archive(Self.errorText(reader, fallback: "The archive is damaged."))
            }
            var name = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
            if isBareCompressed { name = (archivePath.lastPathComponent as NSString).deletingPathExtension }

            guard let relative = Self.safeRelativePath(name) else {
                control.skipEntry(name)
                archive_read_data_skip(reader)
                continue
            }
            if relative.isEmpty || relative.hasPrefix("__MACOSX") {
                archive_read_data_skip(reader)
                continue
            }
            let target = staging.appendingPathComponent(relative)
            guard Self.parentIsSafe(relative, under: staging) else {
                // A folder on the way is a link the archive made: writing through it could escape.
                control.skipEntry(name)
                archive_read_data_skip(reader)
                continue
            }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            control.update { $0.currentItem = relative }

            let type = UInt32(archive_entry_filetype(entry))
            let permissions = archive_entry_perm(entry) & 0o777
            switch type {
            case AE_IFDIR:
                if Self.lstatInfo(target.path) == nil {
                    guard mkdir(target.path, 0o755) == 0 else {
                        throw FileEngineError.posix("Create folder", target.path)
                    }
                }
            case AE_IFLNK:
                guard let link = archive_entry_symlink(entry).map({ String(cString: $0) }) else { break }
                guard symlink(link, target.path) == 0 else { throw FileEngineError.posix("Create link", target.path) }
            case AE_IFREG, 0:
                if let linked = archive_entry_hardlink(entry).map({ String(cString: $0) }) {
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
                    archive_read_data_skip(reader)
                    continue
                }
                let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard output >= 0 else { throw FileEngineError.posix("Create", target.path) }
                defer { close(output) }
                while true {
                    try Task.checkCancellation()
                    try control.waitWhilePaused()
                    let count = archive_read_data(reader, buffer, FileEngine.chunkSize)
                    if count == 0 { break }
                    guard count > 0 else {
                        throw OperationError.archive(Self.errorText(reader, fallback: "The archive is damaged."))
                    }
                    var written = 0
                    while written < count {
                        let result = write(output, buffer + written, count - written)
                        if result < 0, errno == EINTR { continue }
                        guard result > 0 else {
                            // Something else may have filled the disk between checks.
                            if errno == ENOSPC || errno == EDQUOT { throw diskFull }
                            throw FileEngineError.posix("Write", target.path)
                        }
                        written += result
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
                // Like copies, extracted files are on disk before they're shown.
                guard fsync(output) == 0 else { throw FileEngineError.posix("Write", target.path) }
                fchmod(output, permissions == 0 ? 0o644 : permissions)
                var times = [
                    timespec(tv_sec: archive_entry_mtime(entry), tv_nsec: 0),
                    timespec(tv_sec: archive_entry_mtime(entry), tv_nsec: 0),
                ]
                futimens(output, &times)
            default:
                // Devices, pipes and sockets are not extracted.
                control.skipEntry(name)
                archive_read_data_skip(reader)
            }
            control.update { $0.itemsDone += 1 }
        }
        control.update { $0.bytesDone = $0.bytesTotal }
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

    private static func errorText(_ archive: OpaquePointer, fallback: String) -> String {
        archive_error_string(archive).map { String(cString: $0) } ?? fallback
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

        do {
            try writeArchive(sources, to: partial, format: format, control: control)
            guard renamex_np(partial.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                throw FileEngineError.posix("Compress", target.path)
            }
            Self.syncFolder(target.deletingLastPathComponent().path)
            undo.add(.trashCreated(target, fileID: Self.fileID(target)))
        } catch {
            Self.removeQuietly(partial.path)
            throw error
        }
    }

    private func writeArchive(
        _ sources: [URL], to destination: URL, format: ArchiveFormat, control: OperationControl
    ) throws {
        guard let writer = archive_write_new() else {
            throw OperationError.archive("Couldn't start writing the archive.")
        }
        defer { archive_write_free(writer) }
        switch format {
        case .zip: archive_write_set_format_zip(writer)
        case .tarGz:
            archive_write_set_format_pax_restricted(writer)
            archive_write_add_filter_gzip(writer)
        case .sevenZip: archive_write_set_format_7zip(writer)
        }
        guard archive_write_open_filename(writer, destination.path) == ARCHIVE_OK else {
            throw OperationError.archive(Self.errorText(writer, fallback: "Couldn't create the archive."))
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: FileEngine.chunkSize, alignment: 16)
        defer { buffer.deallocate() }

        func add(_ url: URL, as name: String) throws {
            try Task.checkCancellation()
            try control.waitWhilePaused()
            guard let info = Self.lstatInfo(url.path), let entry = archive_entry_new() else { return }
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname(entry, name)
            archive_entry_set_perm(entry, info.st_mode & 0o7777)
            archive_entry_set_mtime(entry, info.st_mtimespec.tv_sec, 0)
            control.update { $0.currentItem = name }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                archive_entry_set_filetype(entry, AE_IFDIR)
                guard archive_write_header(writer, entry) == ARCHIVE_OK else {
                    throw OperationError.archive(Self.errorText(writer, fallback: "Couldn't add \(name)."))
                }
                for child in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
                where child != ".DS_Store" {
                    try add(url.appendingPathComponent(child), as: name + "/" + child)
                }
            case S_IFLNK:
                archive_entry_set_filetype(entry, AE_IFLNK)
                let link = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                archive_entry_set_symlink(entry, link)
                archive_write_header(writer, entry)
            case S_IFREG:
                archive_entry_set_filetype(entry, AE_IFREG)
                archive_entry_set_size(entry, Int64(info.st_size))
                guard archive_write_header(writer, entry) == ARCHIVE_OK else {
                    throw OperationError.archive(Self.errorText(writer, fallback: "Couldn't add \(name)."))
                }
                let input = open(url.path, O_RDONLY)
                guard input >= 0 else { throw FileEngineError.posix("Open", url.path) }
                defer { close(input) }
                while true {
                    try Task.checkCancellation()
                    try control.waitWhilePaused()
                    let count = read(input, buffer, FileEngine.chunkSize)
                    if count == 0 { break }
                    guard count > 0 else { throw FileEngineError.posix("Read", url.path) }
                    guard archive_write_data(writer, buffer, count) == count else {
                        throw OperationError.archive(Self.errorText(writer, fallback: "Couldn't write \(name)."))
                    }
                    control.update { $0.bytesDone += Int64(count) }
                }
            default:
                return
            }
            control.update { $0.itemsDone += 1 }
        }

        for source in sources {
            try add(source, as: source.lastPathComponent)
        }
        guard archive_write_close(writer) == ARCHIVE_OK else {
            throw OperationError.archive(Self.errorText(writer, fallback: "Couldn't finish the archive."))
        }
    }
}
