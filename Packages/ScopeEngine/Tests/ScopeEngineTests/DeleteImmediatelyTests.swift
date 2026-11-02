import Foundation
import Testing

@testable import ScopeEngine

/// Delete Immediately: the engine asks once per disk, naming the disk and
/// every item, before anything is removed, and removes nothing on a no.
@Suite(.serialized) struct DeleteImmediatelyTests {
    let disk: TestVolume
    let other: TestVolume
    let engine: FileEngine

    init() throws {
        disk = try TestVolume(name: "ScopeDeleteA")
        other = try TestVolume(name: "ScopeDeleteB")
        engine = FileEngine(pathGuard: .restricted(to: [disk.mountPoint, other.mountPoint]))
    }

    @Test func sayingNoKeepsEverything() async throws {
        try disk.write("a.txt", "a")
        try disk.write("folder/b.txt", "b")
        let ops = OperationHarness(engine: engine)

        await #expect(throws: OperationError.stoppedByUser) {
            try await ops.run(.deletePermanently([disk.url("a.txt"), disk.url("folder")]))
        }
        #expect(try disk.names() == ["a.txt", "folder"])
        #expect(try disk.read("folder/b.txt") == "b")
        let question = try #require(ops.deletionQuestions.all.first)
        #expect(ops.deletionQuestions.all.count == 1)
        #expect(question.reason == .requested)
        #expect(question.volume == "ScopeDeleteA")
        #expect(question.items.map(\.lastPathComponent) == ["a.txt", "folder"])
    }

    @Test func sayingYesRemovesOnlyTheItemsNamedWithoutFollowingLinks() async throws {
        try disk.write("a.txt", "a")
        try disk.write("folder/sub/b.txt", "b")
        try disk.write("kept.txt", "kept")
        let outside = try other.write("outside/precious.txt", "precious")
        try FileManager.default.createSymbolicLink(
            at: disk.url("folder/link"), withDestinationURL: outside.deletingLastPathComponent())
        var ops = OperationHarness(engine: engine)
        ops.deleteForGood = true

        let record = try await ops.run(.deletePermanently([disk.url("a.txt"), disk.url("folder")]))
        #expect(try disk.names() == ["kept.txt"])
        #expect(try other.read("outside/precious.txt") == "precious")
        // Nothing went to a Trash, so there is nothing to undo.
        #expect(record.steps.isEmpty)
        #expect(ops.deletionQuestions.all.count == 1)
    }

    @Test func asksForEveryDiskBeforeRemovingAnything() async throws {
        try disk.write("x.txt", "x")
        try other.write("y.txt", "y")
        try disk.write("z.txt", "z")
        let questions = Recorded<PermanentDeletion>()
        // Yes for the first disk, no for the second: nothing at all goes.
        await #expect(throws: OperationError.stoppedByUser) {
            try await engine.run(
                FileOperation(.deletePermanently([disk.url("x.txt"), other.url("y.txt"), disk.url("z.txt")])),
                control: OperationControl(), undo: UndoRecorder(), resolveConflict: { _ in (.stop, false) },
                confirmPermanentDeletion: { request in
                    questions.append(request)
                    return questions.all.count == 1
                })
        }
        #expect(questions.all.map { $0.items.map(\.lastPathComponent) } == [["x.txt", "z.txt"], ["y.txt"]])
        #expect(try disk.names() == ["x.txt", "z.txt"])
        #expect(try other.names() == ["y.txt"])
    }

    @Test func refusesPlacesOutsideTheGuard() async throws {
        let ops = OperationHarness(engine: FileEngine(pathGuard: .restricted(to: [disk.mountPoint])))
        try other.write("y.txt", "y")
        await #expect(throws: (any Error).self) {
            try await ops.run(.deletePermanently([other.url("y.txt")]))
        }
        #expect(ops.deletionQuestions.all.isEmpty)
        #expect(try other.names() == ["y.txt"])
    }

    @Test(arguments: [false, true])
    func aReplacementDuringConfirmationIsNeverDeleted(directory: Bool) async throws {
        let selected = directory ? disk.url("selected") : disk.url("selected.txt")
        if directory {
            try disk.write("selected/child.txt", "original")
        } else {
            try disk.write("selected.txt", "original")
        }
        let saved = disk.url("saved-original")
        let replacement = directory ? selected.appendingPathComponent("replacement.txt") : selected
        await #expect(throws: (any Error).self) {
            try await engine.run(
                FileOperation(.deletePermanently([selected])), control: OperationControl(), undo: UndoRecorder(),
                resolveConflict: { _ in (.stop, false) },
                confirmPermanentDeletion: { _ in
                    do {
                        try FileManager.default.moveItem(at: selected, to: saved)
                        try FileManager.default.createDirectory(
                            at: replacement.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try Data("unconfirmed replacement".utf8).write(to: replacement)
                        return true
                    } catch { return false }
                })
        }
        #expect(try String(contentsOf: replacement, encoding: .utf8) == "unconfirmed replacement")
        #expect(FileManager.default.fileExists(atPath: saved.path))
    }

    @Test func aChangeDuringALaterDiskQuestionKeepsTheWholeBatch() async throws {
        let first = try disk.write("first.txt", "original")
        let second = try other.write("second.txt", "second")
        let saved = disk.url("saved.txt")
        await #expect(throws: (any Error).self) {
            try await engine.run(
                FileOperation(.deletePermanently([first, second])), control: OperationControl(), undo: UndoRecorder(),
                resolveConflict: { _ in (.stop, false) },
                confirmPermanentDeletion: { request in
                    guard request.items.contains(second) else { return true }
                    do {
                        try FileManager.default.moveItem(at: first, to: saved)
                        try Data("replacement".utf8).write(to: first)
                        return true
                    } catch { return false }
                })
        }
        #expect(try disk.read("first.txt") == "replacement")
        #expect(try disk.read("saved.txt") == "original")
        #expect(try other.read("second.txt") == "second")
    }

    @Test func aSymlinkReplacementIsNotDeletedOrFollowed() async throws {
        let selected = try disk.write("selected.txt", "original")
        let outside = try other.write("sentinel.txt", "untouched")
        let saved = disk.url("saved.txt")
        await #expect(throws: (any Error).self) {
            try await engine.run(
                FileOperation(.deletePermanently([selected])), control: OperationControl(), undo: UndoRecorder(),
                resolveConflict: { _ in (.stop, false) },
                confirmPermanentDeletion: { _ in
                    do {
                        try FileManager.default.moveItem(at: selected, to: saved)
                        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: outside)
                        return true
                    } catch { return false }
                })
        }
        #expect(try disk.read("saved.txt") == "original")
        #expect((FileEngine.lstatInfo(selected.path)?.st_mode ?? 0) & S_IFMT == S_IFLNK)
        #expect(try other.read("sentinel.txt") == "untouched")
    }
}
