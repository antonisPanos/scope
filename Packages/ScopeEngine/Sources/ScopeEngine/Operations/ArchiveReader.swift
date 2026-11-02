import CArchive
import Foundation

/// One entry of an archive, as its headers describe it. Plain data, so a
/// reader running in another process (an XPC service) can send it over.
public struct ArchiveEntry: Sendable, Codable, Equatable {
    public enum Kind: Sendable, Codable, Equatable {
        case directory
        case file
        case symlink(to: String)
        /// A second name for a file stored earlier in the archive.
        case hardlink(to: String)
        /// Devices, pipes and sockets, which are never extracted.
        case other
    }

    public var name: String
    public var kind: Kind
    /// Permission bits (0o777 at most); 0 when the archive doesn't say.
    public var permissions: UInt16
    /// Modification time in seconds since 1970.
    public var modified: Int64
    /// The unpacked size, when the header records it.
    public var size: Int64?

    public init(name: String, kind: Kind, permissions: UInt16 = 0, modified: Int64 = 0, size: Int64? = nil) {
        self.name = name
        self.kind = kind
        self.permissions = permissions
        self.modified = modified
        self.size = size
    }
}

public enum ArchiveReadError: Error, Equatable, Sendable {
    /// The file isn't an archive this reader understands.
    case notAnArchive
    /// The archive is damaged or uses something unsupported; the reader's message.
    case damaged(String)
}

/// Reads one archive, entry by entry. It is used from one thread at a time.
/// Archives come from anywhere, so the parsing can run apart from the app
/// (see `ArchiveReaderOpening`); the engine still checks every name and
/// writes every file itself.
public protocol ArchiveReading: AnyObject {
    /// The next entry, or nil at the end. Data of the previous entry that
    /// wasn't read is skipped.
    func nextEntry() throws(ArchiveReadError) -> ArchiveEntry?
    /// Up to `limit` bytes of the current entry's data; empty at its end.
    func readData(upTo limit: Int) throws(ArchiveReadError) -> Data
}

/// Opens archives for reading. The engine opens the archive file itself
/// (after the path guard) and hands over only the open file, so a reader
/// needs no access to the disk at all.
public protocol ArchiveReaderOpening: Sendable {
    /// `singleFile`: the file is a bare compressed file (.gz, .xz, .bz2)
    /// with no archive inside, read as one entry.
    func open(_ archive: FileHandle, singleFile: Bool) throws(ArchiveReadError) -> any ArchiveReading
}

/// Reads archives with libarchive in this process.
public struct LibArchiveReaders: ArchiveReaderOpening {
    public init() {}

    public func open(_ archive: FileHandle, singleFile: Bool) throws(ArchiveReadError) -> any ArchiveReading {
        try LibArchiveReader(archive, singleFile: singleFile)
    }
}

final class LibArchiveReader: ArchiveReading {
    private let reader: OpaquePointer
    /// Kept open for as long as libarchive reads from its descriptor.
    private let file: FileHandle

    init(_ file: FileHandle, singleFile: Bool) throws(ArchiveReadError) {
        guard let reader = archive_read_new() else { throw .damaged("Couldn't start reading the archive.") }
        archive_read_support_filter_all(reader)
        archive_read_support_format_all(reader)
        if singleFile { archive_read_support_format_raw(reader) }
        guard archive_read_open_fd(reader, file.fileDescriptor, 64 * 1024) == ARCHIVE_OK else {
            archive_read_free(reader)
            throw .notAnArchive
        }
        self.reader = reader
        self.file = file
    }

    deinit {
        archive_read_free(reader)
    }

    func nextEntry() throws(ArchiveReadError) -> ArchiveEntry? {
        var entry: OpaquePointer?
        let status = archive_read_next_header(reader, &entry)
        if status == ARCHIVE_EOF { return nil }
        guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let entry else { throw .damaged(errorText) }
        let name = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
        let kind: ArchiveEntry.Kind
        switch UInt32(archive_entry_filetype(entry)) {
        case AE_IFDIR:
            kind = .directory
        case AE_IFLNK:
            kind = .symlink(to: archive_entry_symlink(entry).map { String(cString: $0) } ?? "")
        case AE_IFREG, 0:
            if let linked = archive_entry_hardlink(entry).map({ String(cString: $0) }) {
                kind = .hardlink(to: linked)
            } else {
                kind = .file
            }
        default:
            kind = .other
        }
        return ArchiveEntry(
            name: name, kind: kind, permissions: UInt16(archive_entry_perm(entry) & 0o777),
            modified: Int64(archive_entry_mtime(entry)),
            size: archive_entry_size_is_set(entry) != 0 ? Int64(archive_entry_size(entry)) : nil)
    }

    func readData(upTo limit: Int) throws(ArchiveReadError) -> Data {
        var data = Data(count: limit)
        let count = data.withUnsafeMutableBytes { buffer in
            archive_read_data(reader, buffer.baseAddress, limit)
        }
        guard count >= 0 else { throw .damaged(errorText) }
        data.count = count
        return data
    }

    private var errorText: String {
        archive_error_string(reader).map { String(cString: $0) } ?? "The archive is damaged."
    }
}
