import CoreServices
import Foundation
import Testing

@testable import ScopeEngine

struct ArchiveMetadataTests {
    private func fixture(_ sandbox: Sandbox) throws -> URL {
        try sandbox.write("original/nested/note.txt", "data fork sentinel")
        let file = sandbox.url("original/nested/note.txt")
        try set("com.apple.ResourceFork", Data("resource fork sentinel".utf8), on: file)
        var finder = Data(repeating: 0, count: 32)
        finder.replaceSubrange(0..<8, with: Data("TEXTSCPE".utf8))
        try set("com.apple.FinderInfo", finder, on: file)
        let tags = try PropertyListSerialization.data(
            fromPropertyList: ["Project", "Red\n6"], format: .binary, options: 0)
        try set("com.apple.metadata:_kMDItemUserTags", tags, on: file)
        try set("user.scope", Data("custom".utf8), on: sandbox.url("original/nested"))
        #expect(chmod(file.path, 0o444) == 0)
        #expect(chmod(sandbox.url("original/nested").path, 0o750) == 0)
        var times = [timespec(tv_sec: 1_234_000_000, tv_nsec: 0), timespec(tv_sec: 1_234_000_000, tv_nsec: 0)]
        #expect(utimensat(AT_FDCWD, sandbox.url("original/nested").path, &times, AT_SYMLINK_NOFOLLOW) == 0)
        return sandbox.url("original")
    }

    @Test(arguments: ArchiveFormat.allCases, [false, true])
    func roundTripsMacMetadata(format: ArchiveFormat, service: Bool) async throws {
        let sandbox = try Sandbox()
        let original = try fixture(sandbox)
        let before = try TreeSnapshot(original)
        var engine = sandbox.engine
        if service { engine.archiveReaders = ServiceHarness(ArchiveServiceListener()).readers() }
        let ops = OperationHarness(engine: engine)
        try await ops.run(.compress([original], format: format))
        try await ops.run(.extract(sandbox.url("original." + format.fileExtension)))
        #expect(try TreeSnapshot(sandbox.url("original 2")) == before)
        #expect(FileEngine.lstatInfo(sandbox.url("original 2/nested").path)?.st_mtimespec.tv_sec == 1_234_000_000)
    }

    @Test func finderCompatibleZIPsWorkInBothDirections() async throws {
        let sandbox = try Sandbox()
        let original = try fixture(sandbox)
        let before = try TreeSnapshot(original)
        try ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", original.path, sandbox.url("ditto.zip").path])
        try await OperationHarness(engine: sandbox.engine).run(.extract(sandbox.url("ditto.zip")))
        #expect(try TreeSnapshot(sandbox.url("original 2")) == before)

        try await OperationHarness(engine: sandbox.engine).run(.compress([original], format: .zip))
        try sandbox.mkdir("ditto-output")
        try ditto(["-x", "-k", sandbox.url("original.zip").path, sandbox.url("ditto-output").path])
        #expect(try TreeSnapshot(sandbox.url("ditto-output/original")) == before)
    }

    @Test func malformedMetadataIsRejectedAndNeverAppliedThroughLinks() async throws {
        let data = try AppleDouble.encode(["user.test": Data("value".utf8), "com.apple.ResourceFork": Data([1, 2, 3])])
        let prefixed = Data([0]) + data
        #expect(try AppleDouble.decode(prefixed.dropFirst()) == AppleDouble.decode(data))
        for length in [0, 25, 49, 80, 100, 119, data.count - 1] {
            #expect(throws: OperationError.self) { try AppleDouble.decode(Data(data.prefix(length))) }
        }
        var forged = data
        forged.replaceSubrange(30..<34, with: Data(repeating: 255, count: 4))
        #expect(throws: OperationError.self) { try AppleDouble.decode(forged) }

        let sandbox = try Sandbox()
        try sandbox.write("outside/sentinel", "untouched")
        let before = try TreeSnapshot(sandbox.url("outside"))
        var attributes = ArchiveEntry(name: "link", kind: .metadata, size: 0)
        attributes.extendedAttributes = ["user.test": Data("untrusted".utf8)]
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(entries: [
            (ArchiveEntry(name: "link", kind: .symlink(to: sandbox.url("outside/sentinel").path)), nil),
            (attributes, nil),
        ])
        let archive = try sandbox.write("input.bin", "unused")
        await #expect(throws: OperationError.self) { try await OperationHarness(engine: engine).run(.extract(archive)) }
        #expect(try TreeSnapshot(sandbox.url("outside")) == before)
        #expect(try sandbox.names() == ["input.bin", "outside"])
    }

    @Test func unsupportedFileFlagsFailBeforePublishingAnArchive() async throws {
        let sandbox = try Sandbox()
        let file = try sandbox.write("flagged.txt", "sentinel")
        #expect(chflags(file.path, UInt32(UF_NODUMP)) == 0)
        defer { _ = chflags(file.path, 0) }
        await #expect(throws: OperationError.self) {
            try await OperationHarness(engine: sandbox.engine).run(.compress([file], format: .zip))
        }
        #expect(try sandbox.names() == ["flagged.txt"])
    }

    @Test func explicitZeroPermissionsAreKept() async throws {
        let sandbox = try Sandbox()
        let archive = try sandbox.write("mode.bin", "unused")
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(entries: [
            (ArchiveEntry(name: "locked.txt", kind: .file, permissions: 0, size: 0), nil)
        ])
        try await OperationHarness(engine: engine).run(.extract(archive))
        #expect(FileEngine.lstatInfo(sandbox.url("locked.txt").path).map { $0.st_mode & 0o777 } == 0)
    }

    @Test func ordinaryFilesWithMetadataLikeNamesAreKept() async throws {
        let sandbox = try Sandbox()
        let archive = try sandbox.write("names.bin", "unused")
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(entries: [
            (ArchiveEntry(name: "__MACOSX-note.txt", kind: .file), "ordinary data"),
            (ArchiveEntry(name: "__MACOSX/user.txt", kind: .file), "also ordinary data"),
        ])
        try await OperationHarness(engine: engine).run(.extract(archive))
        #expect(try String(contentsOf: sandbox.url("names/__MACOSX-note.txt"), encoding: .utf8) == "ordinary data")
        #expect(try String(contentsOf: sandbox.url("names/__MACOSX/user.txt"), encoding: .utf8) == "also ordinary data")
    }

    @Test(arguments: [false, true]) func repackingDownloadsKeepsQuarantine(folder: Bool) async throws {
        let sandbox = try Sandbox()
        let file = try sandbox.write("original/note.txt", "harmless text")
        var source = file
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "ScopeMetadataTest",
            kLSQuarantineTimeStampKey as String: Date(timeIntervalSince1970: 1_700_000_000),
        ]
        try source.setResourceValues(values)
        let input = folder ? sandbox.url("original") : file
        var engine = sandbox.engine
        engine.archiveReaders = ServiceHarness(ArchiveServiceListener()).readers()
        let ops = OperationHarness(engine: engine)
        try await ops.run(.compress([input], format: .zip))
        let archive = input.appendingPathExtension("zip")
        let properties = try archive.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(properties?[kLSQuarantineAgentNameKey as String] as? String == "ScopeMetadataTest")
        try await ops.run(.extract(archive))
        let extracted = folder ? sandbox.url("original 2/note.txt") : sandbox.url("original/note 2.txt")
        let restored = try extracted.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(restored?[kLSQuarantineAgentNameKey as String] as? String == "ScopeMetadataTest")
    }

    private func set(_ name: String, _ data: Data, on url: URL) throws {
        let result = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        guard result == 0 else { throw FileEngineError.posix("Set fixture attribute", name) }
    }

    private func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
