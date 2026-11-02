import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

/// "Replace If Older": a file replaces the existing one only when the
/// existing one was modified first. Anything else is skipped, folders always.
@Suite(.serialized) struct ReplaceIfOlderTests {
    let source: TestVolume
    let disk: TestVolume
    var ops: OperationHarness

    init() throws {
        source = try TestVolume(name: "ScopeOlderA")
        disk = try TestVolume(name: "ScopeOlderB")
        ops = OperationHarness(engine: FileEngine(pathGuard: .restricted(to: [source.mountPoint, disk.mountPoint])))
        ops.conflictAnswer = .replaceIfOlder
    }

    private func setModified(_ url: URL, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }

    @Test func replacesOnlyFilesWhoseExistingCopyIsOlder() async throws {
        try setModified(try source.write("newer.txt", "incoming newer"), 2_000_000_000)
        try setModified(try source.write("older.txt", "incoming older"), 1_000_000_000)
        try setModified(try disk.write("newer.txt", "existing older"), 1_500_000_000)
        try setModified(try disk.write("older.txt", "existing newer"), 1_500_000_000)

        let record = try await ops.run(.copy([source.url("newer.txt"), source.url("older.txt")], into: disk.work))
        #expect(try disk.read("newer.txt") == "incoming newer")
        #expect(try disk.read("older.txt") == "existing newer")

        // The replaced file went to the Trash and comes back on undo.
        try await ops.undo(record)
        #expect(try disk.read("newer.txt") == "existing older")
    }

    @Test func sameTimeIsNotOlder() async throws {
        try setModified(try source.write("a.txt", "incoming"), 1_500_000_000)
        try setModified(try disk.write("a.txt", "existing"), 1_500_000_000)
        try await ops.run(.copy([source.url("a.txt")], into: disk.work))
        #expect(try disk.read("a.txt") == "existing")
    }

    @Test func foldersAreKept() async throws {
        try source.write("folder/new.txt", "new")
        try setModified(source.url("folder"), 2_000_000_000)
        try disk.write("folder/old.txt", "old")
        try setModified(disk.url("folder"), 1_000_000_000)
        try await ops.run(.copy([source.url("folder")], into: disk.work))
        #expect(try disk.names("folder") == ["old.txt"])
    }

    @Test func theQuestionCarriesBothDates() async throws {
        try setModified(try source.write("a.txt", "incoming"), 2_000_000_000)
        try setModified(try disk.write("a.txt", "existing"), 1_000_000_000)
        let asked = Mutex<[Conflict]>([])
        try await ops.engine.run(
            FileOperation(.copy([source.url("a.txt")], into: disk.work)), control: OperationControl(),
            undo: UndoRecorder()
        ) { conflict in
            asked.withLock { $0.append(conflict) }
            return (.skip, false)
        }
        let conflict = try #require(asked.withLock { $0.first })
        #expect(conflict.incomingModified == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(conflict.existingModified == Date(timeIntervalSince1970: 1_000_000_000))
    }
}
