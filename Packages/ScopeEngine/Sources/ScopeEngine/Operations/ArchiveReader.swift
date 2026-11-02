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
        /// Attributes for an entry named elsewhere (AppleDouble sidecar).
        case metadata
    }

    public var name: String
    public var kind: Kind
    /// Permission bits (0o777 at most); nil when the archive does not say.
    public var permissions: UInt16?
    /// Modification time in seconds since 1970.
    public var modified: Int64
    /// The unpacked size, when the header records it.
    public var size: Int64?
    public var extendedAttributes: [String: Data] = [:]

    public init(name: String, kind: Kind, permissions: UInt16? = nil, modified: Int64 = 0, size: Int64? = nil) {
        self.name = name
        self.kind = kind
        self.permissions = permissions
        self.modified = modified
        self.size = size
    }
}

public enum ArchiveReadError: Error, Equatable, Sendable, Codable {
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
    private var buffered: Data?
    private var bufferedOffset = 0

    init(_ file: FileHandle, singleFile: Bool) throws(ArchiveReadError) {
        guard let reader = archive_read_new() else { throw .damaged("Couldn't start reading the archive.") }
        archive_read_support_filter_all(reader)
        archive_read_support_format_all(reader)
        _ = archive_read_set_option(reader, nil, "mac-ext", "1")
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
        buffered = nil
        bufferedOffset = 0
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
        var result = ArchiveEntry(
            name: name, kind: kind, permissions: UInt16(archive_entry_perm(entry) & 0o777),
            modified: Int64(archive_entry_mtime(entry)),
            size: archive_entry_size_is_set(entry) != 0 ? Int64(archive_entry_size(entry)) : nil)
        do {
            var size = 0
            if let pointer = archive_entry_mac_metadata(entry, &size) {
                guard size >= 0, size <= AppleDouble.limit else { throw AppleDouble.invalid() }
                result.extendedAttributes = try AppleDouble.decode(Data(bytes: pointer, count: size))
            }
            let count = archive_entry_xattr_reset(entry)
            guard count >= 0, count <= 4096 else { throw AppleDouble.invalid() }
            var metadataBytes = result.extendedAttributes.values.reduce(0) { $0 + $1.count }
            for _ in 0..<max(0, count) {
                var name: UnsafePointer<CChar>?
                var value: UnsafeRawPointer?
                var length = 0
                guard archive_entry_xattr_next(entry, &name, &value, &length) == ARCHIVE_OK,
                    let name, length >= 0, length <= AppleDouble.limit - metadataBytes
                else { throw AppleDouble.invalid() }
                metadataBytes += length
                result.extendedAttributes[String(cString: name)] =
                    value.map { Data(bytes: $0, count: length) } ?? Data()
            }
            if case .file = kind, let target = Self.metadataTarget(name) {
                var data = Data()
                while true {
                    let chunk = try rawData(upTo: min(FileEngine.chunkSize, AppleDouble.limit - data.count + 1))
                    if chunk.isEmpty { break }
                    guard chunk.count <= AppleDouble.limit - data.count else { throw AppleDouble.invalid() }
                    data.append(chunk)
                }
                if data.prefix(4) == Data([0, 5, 0x16, 7]) {
                    result.name = target
                    result.kind = .metadata
                    result.size = Int64(data.count)
                    result.extendedAttributes = try AppleDouble.decode(data)
                } else {
                    buffered = data
                }
            }
            return result
        } catch {
            throw .damaged(error.localizedDescription)
        }
    }

    func readData(upTo limit: Int) throws(ArchiveReadError) -> Data {
        if let buffered {
            let count = min(max(0, limit), buffered.count - bufferedOffset)
            defer { bufferedOffset += count }
            return buffered.subdata(in: bufferedOffset..<bufferedOffset + count)
        }
        return try rawData(upTo: limit)
    }

    private func rawData(upTo limit: Int) throws(ArchiveReadError) -> Data {
        var data = Data(count: limit)
        let count = data.withUnsafeMutableBytes { buffer in
            archive_read_data(reader, buffer.baseAddress, limit)
        }
        guard count >= 0 else { throw .damaged(errorText) }
        data.count = count
        return data
    }

    private static func metadataTarget(_ name: String) -> String? {
        var components = name.split(separator: "/").map(String.init)
        guard let last = components.last, last.hasPrefix("._"), last.count > 2 else { return nil }
        if components.first == "__MACOSX" { components.removeFirst() }
        components[components.count - 1] = String(last.dropFirst(2))
        return components.joined(separator: "/")
    }

    private var errorText: String {
        archive_error_string(reader).map { String(cString: $0) } ?? "The archive is damaged."
    }
}
