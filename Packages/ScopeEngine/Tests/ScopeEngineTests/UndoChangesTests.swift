import Foundation
import Testing

@testable import ScopeEngine

/// Undoing a copy, extract or new item moves what it made to the Trash. A
/// file edited in place since keeps its file ID, so undo also compares its
/// modification time and size, and changes nothing unless the user agreed.
@Suite(.serialized) struct UndoChangesTests {
    let disk: TestVolume
    let engine: FileEngine
    let ops: OperationHarness

    init() throws {
        disk = try TestVolume(name: "ScopeUndoEdits")
        engine = FileEngine(pathGuard: .restricted(to: [disk.mountPoint]))
        ops = OperationHarness(engine: engine)
    }

    private func edit(_ relative: String, appending text: String) throws {
        let handle = try FileHandle(forWritingTo: disk.url(relative))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func anEditedCopyIsKeptUntilTheUserAgrees() async throws {
        try disk.write("a.txt", "a")
        try disk.write("b.txt", "b")
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        var record = try await ops.run(.copy([disk.url("a.txt"), disk.url("b.txt")], into: disk.url("dest")))
        let before = FileEngine.fileID(disk.url("dest/a.txt"))
        try edit("dest/a.txt", appending: " and my edits")
        #expect(FileEngine.fileID(disk.url("dest/a.txt")).inode == before.inode)

        #expect(await engine.changedSinceMade(record).map(\.lastPathComponent) == ["a.txt"])
        await #expect(throws: OperationError.changedSince(["a.txt"])) { try await ops.undo(record) }
        // Nothing was undone, not even the unchanged copy.
        #expect(try disk.names("dest") == ["a.txt", "b.txt"])

        record.includesChangedItems = true
        try await ops.undo(record)
        #expect(try disk.names("dest") == [])
    }

    @Test func anUntouchedCopyUndoesWithoutAsking() async throws {
        try disk.write("a.txt", "a")
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let record = try await ops.run(.copy([disk.url("a.txt")], into: disk.url("dest")))
        // Reading or renaming isn't a change.
        _ = try disk.read("dest/a.txt")
        #expect(await engine.changedSinceMade(record).isEmpty)
        try await ops.undo(record)
        #expect(try disk.names("dest") == [])
    }

    @Test func aSameSizeEditIsSeenByItsTime() async throws {
        try disk.write("a.txt", "aaaa")
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let record = try await ops.run(.copy([disk.url("a.txt")], into: disk.url("dest")))
        let handle = try FileHandle(forWritingTo: disk.url("dest/a.txt"))
        try handle.write(contentsOf: Data("bbbb".utf8))
        try handle.close()
        #expect(await engine.changedSinceMade(record).count == 1)
    }

    @Test func aFolderFilledByALaterOperationStillUndoes() async throws {
        try disk.write("a.txt", "a")
        let made = try await ops.run(.newFolder(in: disk.work, name: "made"))
        let moved = try await ops.run(.move([disk.url("a.txt")], into: disk.url("made")))
        try await ops.undo(moved)
        #expect(await engine.changedSinceMade(made).isEmpty)
        try await ops.undo(made)
        #expect(try disk.names() == ["a.txt"])
    }

    @Test(arguments: ["edit", "add", "remove", "replace"])
    func changedDescendantsRequireConfirmation(change: String) async throws {
        try disk.write("source/nested/leaf.txt", "original")
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        var record = try await ops.run(.copy([disk.url("source")], into: disk.url("dest")))
        switch change {
        case "edit": try edit("dest/source/nested/leaf.txt", appending: " edits")
        case "add": try disk.write("dest/source/nested/new.txt", "new")
        case "remove": try FileManager.default.removeItem(at: disk.url("dest/source/nested/leaf.txt"))
        default:
            try FileManager.default.moveItem(at: disk.url("dest/source/nested/leaf.txt"), to: disk.url("saved.txt"))
            try disk.write("dest/source/nested/leaf.txt", "replacement")
        }
        let changed = await engine.changedSinceMade(record)
        #expect(changed.map(\.path) == [disk.url("dest/source").path])
        let before = try TreeSnapshot(disk.url("dest"))
        await #expect(throws: OperationError.self) { try await ops.undo(record) }
        #expect(try TreeSnapshot(disk.url("dest")) == before)
        record.includesChangedItems = true
        try await ops.undo(record)
        #expect(try disk.names("dest").isEmpty)
    }

    @Test func directoryVersionsDoNotFollowLinks() async throws {
        try disk.write("outside/leaf.txt", "outside")
        try FileManager.default.createDirectory(at: disk.url("source"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: disk.url("source/link"), withDestinationURL: disk.url("outside"))
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let record = try await ops.run(.copy([disk.url("source")], into: disk.url("dest")))
        try edit("outside/leaf.txt", appending: " edits")
        #expect(await engine.changedSinceMade(record).isEmpty)
        try await ops.undo(record)
        #expect(try disk.read("outside/leaf.txt") == "outside edits")
    }

    @Test func theCenterAsksBeforeQueueingTheUndo() async throws {
        let center = OperationCenter(engine: engine) { _ in (.stop, false) }
        try disk.write("a.txt", "a")
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let copy = try await center.enqueue(FileOperation(.copy([disk.url("a.txt")], into: disk.url("dest"))))
        await center.waitUntilIdle()
        try edit("dest/a.txt", appending: "!")

        #expect(await center.changedSinceMade(copy).map(\.lastPathComponent) == ["a.txt"])
        let refused = try #require(try await center.undo(copy))
        await center.waitUntilIdle()
        guard case .failed = await center.snapshots().first(where: { $0.id == refused })?.state else {
            Issue.record("The undo should have failed")
            return
        }
        #expect(disk.exists("dest/a.txt"))

        // The copy can still be undone, now with the user's yes.
        #expect(await center.lastUndoable() == copy)
        _ = try await center.undo(copy, includingChanged: true)
        await center.waitUntilIdle()
        #expect(!disk.exists("dest/a.txt"))
    }
}
