import CoreServices
import Foundation
import Testing

@testable import ScopeEngine

struct ArchiveQuarantineTests {
    let sandbox: Sandbox

    init() throws {
        sandbox = try Sandbox()
    }

    @Test(arguments: [false, true])
    func extractedBundleAndDescendantsInheritQuarantine(throughService: Bool) async throws {
        let archive = try sandbox.write(
            "download.tar", TarBuilder().file("Harmless.app/Contents/note.txt", "not executable").data())
        try quarantine(archive)
        let original = try properties(of: archive)
        #expect(original[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)
        #expect(original[kLSQuarantineAgentNameKey as String] as? String == "ScopeAudit")
        var engine = sandbox.engine
        if throughService { engine.archiveReaders = ServiceHarness(ArchiveServiceListener()).readers() }

        try await OperationHarness(engine: engine).run(.extract(archive))
        for name in ["Harmless.app", "Harmless.app/Contents", "Harmless.app/Contents/note.txt"] {
            let inherited = try properties(of: sandbox.url(name))
            #expect(
                inherited[kLSQuarantineTypeKey as String] as? String == original[kLSQuarantineTypeKey as String]
                    as? String)
            #expect(inherited[kLSQuarantineAgentNameKey as String] as? String == "ScopeAudit")
            #expect(
                inherited[kLSQuarantineTimeStampKey as String] as? Date == original[kLSQuarantineTimeStampKey as String]
                    as? Date)
            #expect(getxattr(sandbox.url(name).path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0)
        }
    }

    @Test func aSingleReadOnlyFileIsQuarantinedBeforeItsModeIsSet() async throws {
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(entries: [
            (ArchiveEntry(name: "read-only.txt", kind: .file, permissions: 0o444), "safe text")
        ])
        let archive = try sandbox.write("download.zip", "unused")
        try quarantine(archive)
        try await OperationHarness(engine: engine).run(.extract(archive))
        #expect(getxattr(sandbox.url("read-only.txt").path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0)
        #expect((FileEngine.lstatInfo(sandbox.url("read-only.txt").path)?.st_mode ?? 0) & 0o777 == 0o444)
    }

    @Test func wrapperAndHardLinkedFilesAreQuarantinedWithoutFollowingSymlinks() async throws {
        let outside = try Sandbox()
        let sentinel = try outside.write("untouched.txt", "outside")
        let before = try TreeSnapshot(outside.root)
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(entries: [
            (ArchiveEntry(name: "first.txt", kind: .file), "safe text"),
            (ArchiveEntry(name: "second.txt", kind: .hardlink(to: "first.txt")), nil),
            (ArchiveEntry(name: "link", kind: .symlink(to: sentinel.path)), nil),
        ])
        let archive = try sandbox.write("download.zip", "unused")
        try quarantine(archive)
        try await OperationHarness(engine: engine).run(.extract(archive))
        for name in ["download", "download/first.txt", "download/second.txt"] {
            #expect(getxattr(sandbox.url(name).path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0)
        }
        #expect(try TreeSnapshot(outside.root) == before)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: sandbox.url("download/link").path)
                == sentinel.path)
    }

    @Test func aLocalArchiveDoesNotQuarantineItsOutput() async throws {
        let archive = try sandbox.write("local.tar", TarBuilder().file("note.txt", "safe text").data())
        try await OperationHarness(engine: sandbox.engine).run(.extract(archive))
        #expect(getxattr(sandbox.url("note.txt").path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) == -1)
        #expect(errno == ENOATTR)
    }

    private func quarantine(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "ScopeAudit",
        ]
        try target.setResourceValues(values)
    }

    private func properties(of url: URL) throws -> [String: Any] {
        try #require(url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
    }
}
