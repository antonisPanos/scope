import CArchive
import Foundation

public enum ArchiveWriteError: Error, LocalizedError, Sendable, Codable, Equatable {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

/// Encoded bytes are returned to the engine; a codec never opens an output path.
public typealias ArchiveDataSink = @Sendable (Data) throws(ArchiveWriteError) -> Void

/// Used from one thread at a time, like ArchiveReading. Calls are bounded by
/// chunkSize; finishing may stream many output chunks through the sink.
public protocol ArchiveWriting: AnyObject {
    func beginEntry(_ entry: ArchiveEntry) throws(ArchiveWriteError)
    func writeData(_ data: Data) throws(ArchiveWriteError)
    func finishEntry() throws(ArchiveWriteError)
    func finish() throws(ArchiveWriteError)
    func cancel()
}

public protocol ArchiveWriterOpening: Sendable {
    func open(
        format: ArchiveFormat, control: OperationControl?, output: @escaping ArchiveDataSink
    )
        throws(ArchiveWriteError) -> any ArchiveWriting
}

/// In-process codec for engine clients/tests. The app selects XPCArchiveWriters.
public struct LibArchiveWriters: ArchiveWriterOpening {
    public init() {}

    public func open(
        format: ArchiveFormat, control: OperationControl?, output: @escaping ArchiveDataSink
    )
        throws(ArchiveWriteError) -> any ArchiveWriting
    {
        try LibArchiveWriter(format: format, control: control, output: output)
    }
}

final class LibArchiveWriter: ArchiveWriting {
    private let writer: OpaquePointer
    private let output: CodecOutput
    private let control: OperationControl?
    private var remaining: Int64?
    private var hasEntry = false
    private var finished = false

    init(
        format: ArchiveFormat, control: OperationControl?, output sink: @escaping ArchiveDataSink
    )
        throws(ArchiveWriteError)
    {
        guard let writer = archive_write_new() else { throw .failed("Couldn't start writing the archive.") }
        let output = CodecOutput(sink)
        do {
            let status: Int32
            switch format {
            case .zip: status = archive_write_set_format_zip(writer)
            case .tarGz:
                try Self.check(archive_write_set_format_pax_restricted(writer), writer, output)
                status = archive_write_add_filter_gzip(writer)
            case .sevenZip: status = archive_write_set_format_7zip(writer)
            }
            try Self.check(status, writer, output)
            try Self.check(archive_write_set_bytes_per_block(writer, 64 * 1024), writer, output)
            try Self.check(archive_write_set_bytes_in_last_block(writer, 1), writer, output)
            try Self.check(
                archive_write_open2(
                    writer, Unmanaged.passUnretained(output).toOpaque(), nil,
                    { _, context, bytes, count in
                        guard let context, let bytes, count >= 0 else { return -1 }
                        let output = Unmanaged<CodecOutput>.fromOpaque(context).takeUnretainedValue()
                        do throws(ArchiveWriteError) {
                            var offset = 0
                            while offset < count {
                                let size = min(FileEngine.chunkSize, count - offset)
                                try output.sink(Data(bytes: bytes + offset, count: size))
                                offset += size
                            }
                            return count
                        } catch {
                            output.failure = error
                            return -1
                        }
                    }, nil, nil), writer, output)
        } catch {
            archive_write_fail(writer)
            archive_write_free(writer)
            throw error
        }
        self.writer = writer
        self.output = output
        self.control = control
    }

    deinit {
        if !finished { archive_write_fail(writer) }
        archive_write_free(writer)
    }

    func beginEntry(_ value: ArchiveEntry) throws(ArchiveWriteError) {
        try archiveWriteCheckpoint(control)
        guard !finished, !hasEntry, !value.name.isEmpty, !value.name.utf8.contains(0),
            value.name.utf8.count <= 16 * 1024, value.extendedAttributes.isEmpty,
            let entry = archive_entry_new()
        else { throw .failed("Invalid archive entry or writer state.") }
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname(entry, value.name)
        archive_entry_set_perm(entry, mode_t(value.permissions ?? 0o644) & 0o777)
        archive_entry_set_mtime(entry, Int(value.modified), 0)
        switch value.kind {
        case .directory: archive_entry_set_filetype(entry, AE_IFDIR)
        case .symlink(let target):
            guard !target.utf8.contains(0), target.utf8.count <= 16 * 1024 else {
                throw .failed("Invalid archive link.")
            }
            archive_entry_set_filetype(entry, AE_IFLNK)
            archive_entry_set_symlink(entry, target)
        case .file:
            guard let size = value.size, size >= 0 else { throw .failed("Invalid archive entry size.") }
            archive_entry_set_filetype(entry, AE_IFREG)
            archive_entry_set_size(entry, size)
        default: throw .failed("Unsupported archive entry type.")
        }
        try Self.check(archive_write_header(writer, entry), writer, output)
        remaining = value.kind == .file ? value.size : nil
        hasEntry = true
    }

    func writeData(_ data: Data) throws(ArchiveWriteError) {
        try archiveWriteCheckpoint(control)
        guard !finished, hasEntry, let remaining, data.count <= FileEngine.chunkSize,
            Int64(data.count) <= remaining
        else { throw .failed("Invalid archive data or changed source size.") }
        let written = data.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, data.count) }
        guard written == data.count else {
            throw output.failure ?? .failed(Self.message(writer))
        }
        self.remaining = remaining - Int64(data.count)
    }

    func finishEntry() throws(ArchiveWriteError) {
        try archiveWriteCheckpoint(control)
        guard !finished, hasEntry, remaining == nil || remaining == 0 else {
            throw .failed("The source changed size while it was being compressed.")
        }
        try Self.check(archive_write_finish_entry(writer), writer, output)
        hasEntry = false
        remaining = nil
    }

    func finish() throws(ArchiveWriteError) {
        try archiveWriteCheckpoint(control)
        guard !finished, !hasEntry else { throw .failed("Invalid archive writer state.") }
        try Self.check(archive_write_close(writer), writer, output)
        finished = true
    }

    func cancel() {
        if !finished {
            archive_write_fail(writer)
            finished = true
        }
    }

    private static func check(
        _ status: Int32, _ writer: OpaquePointer, _ output: CodecOutput
    )
        throws(ArchiveWriteError)
    {
        guard status == ARCHIVE_OK else { throw output.failure ?? .failed(message(writer)) }
    }

    private static func message(_ writer: OpaquePointer) -> String {
        archive_error_string(writer).map { String(cString: $0) } ?? "Couldn't write the archive."
    }
}

private final class CodecOutput {
    let sink: ArchiveDataSink
    var failure: ArchiveWriteError?

    init(_ sink: @escaping ArchiveDataSink) { self.sink = sink }
}

func archiveWriteCheckpoint(_ control: OperationControl?) throws(ArchiveWriteError) {
    do {
        try Task.checkCancellation()
        try control?.waitWhilePaused()
    } catch {
        throw .failed("Compression was cancelled.")
    }
}
