import Foundation
import Testing

@testable import ScopeEngine

/// Sidecars and an entry's own attributes apply in arrival order, so the
/// latest wins and keys only an earlier one set are kept (#160). A few
/// synthetic entries in a temporary folder; nothing else is touched.
@Suite struct SidecarOrderTests {
    let sandbox: Sandbox

    init() throws {
        sandbox = try Sandbox()
    }

    private func sidecar(_ name: String, _ attributes: [String: String]) -> (ArchiveEntry, String?) {
        var entry = ArchiveEntry(name: name, kind: .metadata, size: 0)
        entry.extendedAttributes = attributes.mapValues { Data($0.utf8) }
        return (entry, nil)
    }

    private func entry(
        _ name: String, _ kind: ArchiveEntry.Kind, _ attributes: [String: String] = [:], contents: String? = nil
    ) -> (ArchiveEntry, String?) {
        var entry = ArchiveEntry(name: name, kind: kind)
        entry.extendedAttributes = attributes.mapValues { Data($0.utf8) }
        return (entry, contents)
    }

    /// Extracts `entries` plus a second top-level file, so the result is in
    /// a folder named after the archive, and returns that folder.
    private func extract(_ entries: [(ArchiveEntry, String?)], limits: ExtractionLimits = .init()) async throws -> URL {
        let archive = try sandbox.write("order.bin", "unused")
        var engine = sandbox.engine
        engine.extractionLimits = limits
        engine.archiveReaders = FakeReaders(entries: entries + [entry("other.txt", .file, contents: "o")])
        try await OperationHarness(engine: engine).run(.extract(archive))
        return sandbox.url("order")
    }

    private func attribute(_ name: String, at url: URL) -> String? {
        let length = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length >= 0 else { return nil }
        var value = Data(count: length)
        _ = value.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
        return String(decoding: value, as: UTF8.self)
    }

    @Test func aLaterSidecarWinsForAFolderMadeAsAParent() async throws {
        let root = try await extract([
            sidecar("folder", ["user.test": "early", "user.early": "kept"]),
            entry("folder/note.txt", .file, contents: "n"),
            sidecar("folder", ["user.test": "later", "user.later": "added"]),
        ])
        let folder = root.appendingPathComponent("folder")
        #expect(attribute("user.test", at: folder) == "later")
        #expect(attribute("user.early", at: folder) == "kept")
        #expect(attribute("user.later", at: folder) == "added")
        #expect(try String(contentsOf: folder.appendingPathComponent("note.txt"), encoding: .utf8) == "n")
    }

    @Test func aLaterFolderEntryWinsOverAnEarlierSidecar() async throws {
        let root = try await extract([
            sidecar("folder", ["user.test": "early", "user.early": "kept"]),
            entry("folder/note.txt", .file, contents: "n"),
            entry("folder", .directory, ["user.test": "entry"]),
        ])
        let folder = root.appendingPathComponent("folder")
        #expect(attribute("user.test", at: folder) == "entry")
        #expect(attribute("user.early", at: folder) == "kept")
    }

    @Test func aFileEntryWinsOverItsEarlierSidecar() async throws {
        let root = try await extract([
            sidecar("note.txt", ["user.test": "early", "user.early": "kept"]),
            entry("note.txt", .file, ["user.test": "entry"], contents: "n"),
        ])
        let file = root.appendingPathComponent("note.txt")
        #expect(attribute("user.test", at: file) == "entry")
        #expect(attribute("user.early", at: file) == "kept")
    }

    @Test func aSidecarAfterItsFileStillWins() async throws {
        let root = try await extract([
            entry("note.txt", .file, ["user.test": "entry"], contents: "n"),
            sidecar("note.txt", ["user.test": "later"]),
        ])
        #expect(attribute("user.test", at: root.appendingPathComponent("note.txt")) == "later")
    }

    /// A held sidecar is released once its folder exists, so it no longer
    /// counts against the budget: without that, the second one wouldn't fit.
    @Test func aHeldSidecarIsReleasedWhenItsFolderAppears() async throws {
        var limits = ExtractionLimits()
        limits.pendingMetadataBytes = 100
        let value = String(repeating: "v", count: 60)
        let entries = [
            sidecar("folder", ["user.test": value]),
            entry("folder/note.txt", .file, contents: "n"),
            sidecar("folder", ["user.test": "later"]),
            sidecar("second.txt", ["user.test": value]),
            entry("second.txt", .file, contents: "s"),
        ]
        let root = try await extract(entries, limits: limits)
        #expect(attribute("user.test", at: root.appendingPathComponent("folder")) == "later")
        #expect(attribute("user.test", at: root.appendingPathComponent("second.txt")) == value)
    }
}
