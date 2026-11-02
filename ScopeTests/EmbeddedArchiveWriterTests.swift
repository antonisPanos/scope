import CryptoKit
import Foundation
import ScopeEngine
import Synchronization
import Testing

@testable import Scope

@MainActor struct EmbeddedArchiveWriterTests {
    @Test func theAppUsesTheSandboxedWriter() {
        #expect(BuildIdentity.current.makeEngine().archiveWriters is XPCArchiveWriters)
    }

    @Test(arguments: ArchiveFormat.allCases) func embeddedServiceEncodesWithoutUserFileAccess(
        format: ArchiveFormat
    ) async throws {
        let name = BuildIdentity.archiveServiceName
        let encoded = try await Task.detached {
            var text = Data(count: 6 * 1024 * 1024 + 19)
            text.withUnsafeMutableBytes { bytes in
                var state: UInt64 = 0x1234_5678_90ab_cdef
                for index in bytes.indices {
                    state ^= state << 13
                    state ^= state >> 7
                    state ^= state << 17
                    bytes[index] = UInt8(truncatingIfNeeded: state)
                }
            }
            let encoded = try Self.encode(text, format: format, with: XPCArchiveWriters.embedded(name))
            let reference = try Self.encode(text, format: format, with: LibArchiveWriters())
            #expect(encoded.count == reference.count)
            var comparable = encoded
            var expected = reference
            // gzip records the current time in its outer header. Encoding
            // the reference can cross a second even for identical contents.
            if format == .tarGz, comparable.count >= 10, expected.count >= 10 {
                comparable.resetBytes(in: 4..<8)
                expected.resetBytes(in: 4..<8)
            }
            #expect(SHA256.hash(data: comparable) == SHA256.hash(data: expected), "\(format.rawValue)")
            return encoded
        }.value
        let signature: [UInt8]
        switch format {
        case .zip: signature = [0x50, 0x4b, 3, 4]
        case .tarGz: signature = [0x1f, 0x8b]
        case .sevenZip: signature = [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]
        }
        #expect(encoded.starts(with: signature))
        #expect(encoded.count > signature.count)
    }

    private nonisolated static func encode(
        _ text: Data, format: ArchiveFormat, with factory: any ArchiveWriterOpening
    )
        throws -> Data
    {
        let bytes = Mutex(Data())
        let writer = try factory.open(format: format, control: nil) { data in bytes.withLock { $0.append(data) } }
        defer { writer.cancel() }
        try writer.beginEntry(ArchiveEntry(name: "note.bin", kind: .file, permissions: 0o644, size: Int64(text.count)))
        var offset = 0
        while offset < text.count {
            let end = min(text.count, offset + FileEngine.chunkSize)
            try writer.writeData(text.subdata(in: offset..<end))
            offset = end
        }
        try writer.finishEntry()
        try writer.finish()
        return bytes.withLock { $0 }
    }
}
