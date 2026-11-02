import Foundation
import Testing

@testable import ScopeEngine

struct ArchiveSizeTests {
    let sandbox: Sandbox

    init() throws {
        sandbox = try Sandbox()
    }

    @Test(arguments: [[Int64.max - 1, 1], [Int64.max, 1], [1 << 62, 1 << 62], [-1]])
    func impossibleDeclaredTotalsAreRefused(_ sizes: [Int64]) async throws {
        let service = ServiceHarness(
            ArchiveServiceListener(
                readers: FakeReaders(
                    entries: sizes.enumerated().map { index, size in
                        (ArchiveEntry(name: "file-\(index)", kind: .file, size: size), nil)
                    })))
        var engine = sandbox.engine
        engine.archiveReaders = service.readers()
        let archive = try sandbox.write("impossible.zip", "headers supplied by the service")

        #expect(engine.declaredUnpackedSize(archive) == Int64.max)
        #expect(await engine.extractionSpaceProblem(archive) != nil)
        await #expect(throws: OperationError.self) {
            try await OperationHarness(engine: engine).run(.extract(archive))
        }
        #expect(try sandbox.names() == ["impossible.zip"])
    }

    @Test func aLargeRepresentableTotalIsNotWrappedOrRejectedAsUnknown() throws {
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(entries: [
            (ArchiveEntry(name: "a", kind: .file, size: .max - 10), nil),
            (ArchiveEntry(name: "b", kind: .file, size: 9), nil),
        ])
        let archive = try sandbox.write("large.zip", "unused")
        #expect(engine.declaredUnpackedSize(archive) == Int64.max - 1)
    }

    @Test(arguments: [false, true])
    func overflowingZIP64IsRefusedBeforeAnythingIsExtracted(throughService: Bool) async throws {
        // A 258-byte ZIP64 with two zero-data entries declaring 2^62 bytes
        // each. No payload is allocated or extracted; libarchive reads its
        // real headers, either directly or across the XPC boundary.
        let encoded =
            "UEsDBC0AAAAAAAAAAAAAAAAA//////////8BABQAYQEAEAAAAAAAAAAAQAAAAAAAAAAA"
            + "UEsDBC0AAAAAAAAAAAAAAAAA//////////8BABQAYgEAEAAAAAAAAAAAQAAAAAAAAAAA"
            + "UEsBAi0ALQAAAAAAAAAAAAAAAAD//////////wEAFAAAAAAAAAAAAAAAAAAAAGEBABAA"
            + "AAAAAAAAAEAAAAAAAAAAAFBLAQItAC0AAAAAAAAAAAAAAAAA//////////8BABQAAAAA"
            + "AAAAAAAAADMAAABiAQAQAAAAAAAAAABAAAAAAAAAAABQSwUGAAAAAAIAAgCGAAAAZgAA"
            + "AAAA"
        let data = try #require(Data(base64Encoded: encoded))
        #expect(data.count == 258)
        let archive = try sandbox.write("overflow.zip", data)
        var engine = sandbox.engine
        if throughService {
            engine.archiveReaders = ServiceHarness(ArchiveServiceListener()).readers()
        }

        #expect(engine.declaredUnpackedSize(archive) == Int64.max)
        #expect(await engine.extractionSpaceProblem(archive) != nil)
        await #expect(throws: OperationError.self) {
            try await OperationHarness(engine: engine).run(.extract(archive))
        }
        #expect(try sandbox.names() == ["overflow.zip"])
    }
}
