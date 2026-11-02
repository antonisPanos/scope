import Foundation
import Testing

@testable import ScopeEngine

/// Deleting on a disk with no Trash: Scope asks once, naming the disk and
/// every item, and removes them for good only on a yes. The test disk
/// stands in for such a disk by having the engine's Trash refuse it.
@Suite(.serialized) struct NoTrashTests {
    let disk: TestVolume
    let noTrash: TestVolume
    let engine: FileEngine

    init() throws {
        disk = try TestVolume(name: "ScopeTrashOK")
        noTrash = try TestVolume(name: "ScopeNoTrash")
        var engine = FileEngine(pathGuard: .restricted(to: [disk.mountPoint, noTrash.mountPoint]))
        let refused = noTrash.mountPoint.path + "/"
        engine.trashRefusal = { $0.path.hasPrefix(refused) }
        self.engine = engine
    }

    @Test func sayingNoKeepsEverything() async throws {
        try noTrash.write("a.txt", "a")
        try noTrash.write("folder/b.txt", "b")
        let ops = OperationHarness(engine: engine)

        await #expect(throws: OperationError.noTrash("ScopeNoTrash")) {
            try await ops.run(.trash([noTrash.url("a.txt"), noTrash.url("folder")]))
        }
        #expect(try noTrash.names() == ["a.txt", "folder"])
        #expect(try noTrash.read("folder/b.txt") == "b")
        let question = try #require(ops.deletionQuestions.all.first)
        #expect(ops.deletionQuestions.all.count == 1)
        #expect(question.volume == "ScopeNoTrash")
        #expect(question.items.map(\.lastPathComponent) == ["a.txt", "folder"])
    }

    @Test func sayingYesRemovesOnlyTheItemsNamedWithoutFollowingLinks() async throws {
        try noTrash.write("a.txt", "a")
        try noTrash.write("folder/sub/b.txt", "b")
        try noTrash.write("kept.txt", "kept")
        let outside = try disk.write("outside/precious.txt", "precious")
        try FileManager.default.createSymbolicLink(
            at: noTrash.url("folder/link"), withDestinationURL: outside.deletingLastPathComponent())
        var ops = OperationHarness(engine: engine)
        ops.deleteForGood = true

        let record = try await ops.run(.trash([noTrash.url("a.txt"), noTrash.url("folder")]))
        #expect(try noTrash.names() == ["kept.txt"])
        #expect(try disk.read("outside/precious.txt") == "precious")
        // Nothing went to a Trash, so there is nothing to undo.
        #expect(record.steps.isEmpty)
        #expect(ops.deletionQuestions.all.count == 1)
    }

    @Test func itemsOnDisksWithATrashStillGoToIt() async throws {
        try disk.write("x.txt", "x")
        try noTrash.write("y.txt", "y")
        try disk.write("z.txt", "z")
        try noTrash.write("w.txt", "w")
        var ops = OperationHarness(engine: engine)
        ops.deleteForGood = true

        let record = try await ops.run(
            .trash([disk.url("x.txt"), noTrash.url("y.txt"), disk.url("z.txt"), noTrash.url("w.txt")]))
        #expect(try disk.names() == [])
        #expect(try noTrash.names() == [])
        // One question, naming both items on the disk without a Trash.
        #expect(ops.deletionQuestions.all.map { $0.items.map(\.lastPathComponent) } == [["y.txt", "w.txt"]])
        #expect(record.steps.count == 2)
        try await ops.undo(record)
        #expect(try disk.names() == ["x.txt", "z.txt"])
    }

    @Test func aCancelWhileTheQuestionIsOpenDeletesNothing() async throws {
        try noTrash.write("a.txt", "a")
        let engine = engine
        let url = noTrash.url("a.txt")
        let task = Task {
            try await engine.run(
                FileOperation(.trash([url])), control: OperationControl(), undo: UndoRecorder(),
                resolveConflict: { _ in (.stop, false) },
                confirmPermanentDeletion: { _ in
                    try? await Task.sleep(for: .seconds(2))
                    return true
                })
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try noTrash.names() == ["a.txt"])
    }

    @Test func aVolumeRootIsNeverDeleted() async throws {
        #expect(throws: PathGuardViolation.self) { try engine.deletePermanently(noTrash.mountPoint) }
        #expect(throws: (any Error).self) { try engine.deletePermanently(noTrash.work.appendingPathComponent("..")) }
        #expect(FileManager.default.fileExists(atPath: noTrash.work.path))
    }

    @Test func aReplacementWhileConfirmingTheNoTrashFallbackIsKept() async throws {
        let selected = try noTrash.write("selected.txt", "original")
        let saved = noTrash.url("saved.txt")
        await #expect(throws: (any Error).self) {
            try await engine.run(
                FileOperation(.trash([selected])), control: OperationControl(), undo: UndoRecorder(),
                resolveConflict: { _ in (.stop, false) },
                confirmPermanentDeletion: { _ in
                    do {
                        try FileManager.default.moveItem(at: selected, to: saved)
                        try Data("replacement".utf8).write(to: selected)
                        return true
                    } catch { return false }
                })
        }
        #expect(try noTrash.read("selected.txt") == "replacement")
        #expect(try noTrash.read("saved.txt") == "original")
    }

    @Test func recognisesADiskWithoutATrash() {
        #expect(FileEngine.isTrashUnavailable(CocoaError(.featureUnsupported)))
        #expect(FileEngine.isTrashUnavailable(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))))
        let wrapped = NSError(
            domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EOPNOTSUPP))])
        #expect(FileEngine.isTrashUnavailable(wrapped))
        #expect(!FileEngine.isTrashUnavailable(CocoaError(.fileWriteNoPermission)))
        #expect(!FileEngine.isTrashUnavailable(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }
}
