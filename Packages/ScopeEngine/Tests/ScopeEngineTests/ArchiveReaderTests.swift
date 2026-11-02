import Foundation
import Testing

@testable import ScopeEngine

/// Archives are parsed by a replaceable reader (libarchive here, a sandboxed
/// service in the app). The engine still checks every name it is given and
/// writes every file itself, so a reader can't place anything outside the
/// extraction folder.
struct ArchiveReaderTests {
    let sandbox: Sandbox

    init() throws {
        sandbox = try Sandbox()
    }

    @Test func libarchiveReadsEntriesFromAnOpenFile() throws {
        let tar = TarBuilder()
            .file("folder/a.txt", "hello")
            .symlink("link", to: "folder/a.txt")
            .data()
        try sandbox.write("t.tar", tar)
        let file = try #require(FileEngine.openForReading(sandbox.url("t.tar")))
        let reader = try LibArchiveReaders().open(file, singleFile: false)

        let first = try #require(try reader.nextEntry())
        #expect(first.name == "folder/a.txt")
        #expect(first.kind == .file)
        #expect(first.size == 5)
        #expect(first.permissions == 0o644)
        #expect(try reader.readData(upTo: 3) == Data("hel".utf8))
        #expect(try reader.readData(upTo: 100) == Data("lo".utf8))
        #expect(try reader.readData(upTo: 100).isEmpty)

        let second = try #require(try reader.nextEntry())
        #expect(second.name == "link")
        #expect(second.kind == .symlink(to: "folder/a.txt"))
        #expect(try reader.nextEntry() == nil)
    }

    @Test func libarchiveSkipsDataThatWasntRead() throws {
        let tar = TarBuilder().file("a.txt", "aaaa").file("b.txt", "bbbb").data()
        try sandbox.write("t.tar", tar)
        let file = try #require(FileEngine.openForReading(sandbox.url("t.tar")))
        let reader = try LibArchiveReaders().open(file, singleFile: false)
        #expect(try reader.nextEntry()?.name == "a.txt")
        #expect(try reader.nextEntry()?.name == "b.txt")
        #expect(try reader.readData(upTo: 100) == Data("bbbb".utf8))
    }

    @Test func libarchiveRefusesAFileThatIsntAnArchive() throws {
        try sandbox.write("plain.zip", "just text, not a zip")
        let file = try #require(FileEngine.openForReading(sandbox.url("plain.zip")))
        #expect(throws: ArchiveReadError.self) {
            let reader = try LibArchiveReaders().open(file, singleFile: false)
            _ = try reader.nextEntry()
        }
    }

    @Test func openingForReadingDoesntFollowALinkAtTheArchivesName() throws {
        try sandbox.write("real.tar", TarBuilder().file("a.txt", "a").data())
        try sandbox.symlink("link.tar", to: "real.tar")
        #expect(FileEngine.openForReading(sandbox.url("link.tar")) == nil)
    }

    @Test func extractionUsesTheInjectedReader() async throws {
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(entries: [
            (ArchiveEntry(name: "docs", kind: .directory), nil),
            (
                ArchiveEntry(name: "docs/note.txt", kind: .file, permissions: 0o600, modified: 1_000_000),
                "from the fake"
            ),
            (ArchiveEntry(name: "alias", kind: .symlink(to: "docs/note.txt")), nil),
        ])
        // The engine opens the file itself, so it has to exist; its bytes
        // don't matter to the fake reader.
        try sandbox.write("fake.zip", "not read")
        try await OperationHarness(engine: engine).run(.extract(sandbox.url("fake.zip")))

        #expect(try String(contentsOf: sandbox.url("fake/docs/note.txt"), encoding: .utf8) == "from the fake")
        let info = try #require(FileEngine.lstatInfo(sandbox.url("fake/docs/note.txt").path))
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_mtimespec.tv_sec == 1_000_000)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: sandbox.url("fake/alias").path)
                == "docs/note.txt")
    }

    @Test func namesFromTheReaderAreStillChecked() async throws {
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(entries: [
            (ArchiveEntry(name: "../escaped.txt", kind: .file), "escape"),
            (ArchiveEntry(name: "/tmp/scope-absolute-\(UUID().uuidString).txt", kind: .file), "absolute"),
            (ArchiveEntry(name: "out", kind: .symlink(to: "/etc")), nil),
            (ArchiveEntry(name: "out/scope-test.txt", kind: .file), "through the link"),
            (ArchiveEntry(name: "copy", kind: .hardlink(to: "../../etc/hosts")), nil),
            (ArchiveEntry(name: "device", kind: .other), nil),
            (ArchiveEntry(name: "innocent.txt", kind: .file), "fine"),
        ])
        try sandbox.write("evil.zip", "not read")
        let control = OperationControl()
        try await OperationHarness(engine: engine).run(.extract(sandbox.url("evil.zip")), control: control)

        #expect(control.skippedEntries.count == 5)
        #expect(try sandbox.names() == ["evil", "evil.zip"])
        #expect(try sandbox.names(in: "evil") == ["innocent.txt", "out"])
        #expect(try String(contentsOf: sandbox.url("evil/innocent.txt"), encoding: .utf8) == "fine")
        #expect(!FileManager.default.fileExists(atPath: "/etc/scope-test.txt"))
    }

    @Test func aReaderFailureLeavesNothingBehind() async throws {
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(
            entries: [(ArchiveEntry(name: "a.txt", kind: .file), "a")], failAtEnd: "Damaged at the end")
        try sandbox.write("broken.zip", "not read")
        await #expect(throws: OperationError.archive("Damaged at the end")) {
            try await OperationHarness(engine: engine).run(.extract(sandbox.url("broken.zip")))
        }
        #expect(try sandbox.names() == ["broken.zip"])
    }

    @Test func declaredSizeComesFromTheReader() throws {
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(entries: [
            (ArchiveEntry(name: "a", kind: .file, size: 10), nil),
            (ArchiveEntry(name: "b", kind: .file, size: 32), nil),
        ])
        try sandbox.write("sized.zip", "not read")
        #expect(engine.declaredUnpackedSize(sandbox.url("sized.zip")) == 42)

        engine.archiveReaders = FakeReaders(entries: [(ArchiveEntry(name: "a", kind: .file), nil)])
        #expect(engine.declaredUnpackedSize(sandbox.url("sized.zip")) == nil)
    }
}

/// A reader that returns entries given by the test, whatever the file holds.
struct FakeReaders: ArchiveReaderOpening {
    let entries: [(ArchiveEntry, String?)]
    var failAtEnd: String?

    func open(_ archive: FileHandle, singleFile: Bool) throws(ArchiveReadError) -> any ArchiveReading {
        FakeReader(entries: entries, failAtEnd: failAtEnd)
    }
}

final class FakeReader: ArchiveReading {
    private var remaining: [(ArchiveEntry, String?)]
    private var data = Data()
    private let failAtEnd: String?

    init(entries: [(ArchiveEntry, String?)], failAtEnd: String?) {
        remaining = entries
        self.failAtEnd = failAtEnd
    }

    func nextEntry() throws(ArchiveReadError) -> ArchiveEntry? {
        guard !remaining.isEmpty else {
            if let failAtEnd { throw .damaged(failAtEnd) }
            return nil
        }
        let (entry, contents) = remaining.removeFirst()
        data = Data((contents ?? "").utf8)
        return entry
    }

    func readData(upTo limit: Int) throws(ArchiveReadError) -> Data {
        let chunk = data.prefix(limit)
        data = data.dropFirst(chunk.count)
        return Data(chunk)
    }
}
