import Foundation
import Testing

@testable import ScopeEngine

@Suite(.serialized) struct OperationCenterTests {
    let disk: TestVolume
    /// Big files are copied from here. A copy within one disk is a clone and
    /// finishes at once, which would leave nothing running to test.
    let source: TestVolume
    let center: OperationCenter

    init() throws {
        disk = try TestVolume(name: "ScopeQueue")
        source = try TestVolume(name: "ScopeQueueSource")
        let engine = FileEngine(pathGuard: .restricted(to: [disk.mountPoint, source.mountPoint]))
        center = OperationCenter(engine: engine) { _ in (.keepBoth, false) }
    }

    private func state(_ id: UUID) async -> OperationCenter.State? {
        await center.snapshots().first { $0.id == id }?.state
    }

    @Test func runsOperationsOnOneDiskOneAtATime() async throws {
        try source.write("big.bin", Data(count: 32 * 1024 * 1024))
        try FileManager.default.createDirectory(at: disk.url("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disk.url("b"), withIntermediateDirectories: true)
        let first = try await center.enqueue(FileOperation(.copy([source.url("big.bin")], into: disk.url("a"))))
        let second = try await center.enqueue(FileOperation(.newFolder(in: disk.url("b"), name: "made")))
        #expect(await state(first) == .running)
        #expect(await state(second) == .queued)
        await center.waitUntilIdle()
        #expect(await state(first) == .done)
        #expect(await state(second) == .done)
        #expect(disk.exists("a/big.bin") && disk.exists("b/made"))
    }

    @Test func refusesOperationsOnLockedItemsAndMergesRepeats() async throws {
        try source.write("big.bin", Data(count: 64 * 1024 * 1024))
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let copy = FileOperation(.copy([source.url("big.bin")], into: disk.url("dest")))
        let id = try await center.enqueue(copy)
        // Pressing Cmd+V again while it runs gives back the same operation.
        #expect(try await center.enqueue(copy) == id)
        // Trashing the file being copied is refused.
        await #expect(throws: OperationError.self) {
            try await center.enqueue(FileOperation(.trash([source.url("big.bin")])))
        }
        await center.waitUntilIdle()
        #expect(await center.snapshots().count == 1)
    }

    @Test func refusesToTrashTheFolderACopyIsWritingInto() async throws {
        try source.write("big.bin", Data(count: 96 * 1024 * 1024))
        try disk.write("small.txt", "s")
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let copy = try await center.enqueue(FileOperation(.copy([source.url("big.bin")], into: disk.url("dest"))))
        await center.pause(copy)

        await #expect(throws: OperationError.self) {
            try await center.enqueue(FileOperation(.trash([disk.url("dest")])))
        }
        // A second copy into the same folder is fine: it only adds to it. So is
        // trashing something else that is in that folder.
        try disk.write("dest/other.txt", "o")
        _ = try await center.enqueue(FileOperation(.copy([disk.url("small.txt")], into: disk.url("dest"))))
        _ = try await center.enqueue(FileOperation(.trash([disk.url("dest/other.txt")])))
        await center.cancel(copy)
        await center.waitUntilIdle()
    }

    @Test func locksMatchOtherSpellingsOfTheSamePath() async throws {
        try source.write("big.bin", Data(count: 96 * 1024 * 1024))
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let copy = try await center.enqueue(FileOperation(.copy([source.url("big.bin")], into: disk.url("dest"))))
        await center.pause(copy)

        // The file being copied, reached through a symlinked folder, and in other case.
        try FileManager.default.createSymbolicLink(at: source.url("alias"), withDestinationURL: source.work)
        await #expect(throws: OperationError.self) {
            try await center.enqueue(FileOperation(.trash([source.url("alias/big.bin")])))
        }
        await #expect(throws: OperationError.self) {
            try await center.enqueue(FileOperation(.trash([source.url("BIG.bin")])))
        }
        await center.cancel(copy)
        await center.waitUntilIdle()
    }

    @Test func pausesResumesAndCancels() async throws {
        try source.write("big.bin", Data(count: 96 * 1024 * 1024))
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let id = try await center.enqueue(FileOperation(.copy([source.url("big.bin")], into: disk.url("dest"))))
        while await center.snapshots().first?.progress.bytesDone ?? 0 == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }

        await center.pause(id)
        #expect(await state(id) == .paused)
        // The chunk in flight when pausing still finishes.
        try await Task.sleep(for: .milliseconds(100))
        let pausedAt = await center.snapshots()[0].progress.bytesDone
        try await Task.sleep(for: .milliseconds(200))
        #expect(await center.snapshots()[0].progress.bytesDone == pausedAt)

        await center.resume(id)
        let cancelledAt = ContinuousClock.now
        await center.cancel(id)
        await center.waitUntilIdle()
        #expect(ContinuousClock.now - cancelledAt < .milliseconds(500))
        #expect(await state(id) == .cancelled)
        #expect(try disk.names("dest") == [])
    }

    @Test func cancelsAQueuedOperationAndUndoesAFinishedOne() async throws {
        try disk.write("a.txt", "a")
        try source.write("big.bin", Data(count: 32 * 1024 * 1024))
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let running = try await center.enqueue(FileOperation(.copy([source.url("big.bin")], into: disk.url("dest"))))
        let queued = try await center.enqueue(FileOperation(.rename(disk.url("a.txt"), to: "b.txt")))
        await center.cancel(queued)
        await center.waitUntilIdle()
        #expect(await state(queued) == .cancelled)
        #expect(disk.exists("a.txt"))

        #expect(await center.lastUndoable() == running)
        try await center.undo(running)
        await center.waitUntilIdle()
        #expect(try disk.names("dest") == [])
        #expect(await center.lastUndoable() == nil)
    }

    @Test func anUndoRefusedWhileItemsAreBusyCanBeRetried() async throws {
        try source.write("a.txt", Data(count: 96 * 1024 * 1024))
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let renamed = try await center.enqueue(FileOperation(.rename(source.url("a.txt"), to: "b.txt")))
        await center.waitUntilIdle()

        // A paused copy of the renamed file holds it, so the undo is refused.
        let copy = try await center.enqueue(FileOperation(.copy([source.url("b.txt")], into: disk.url("dest"))))
        await center.pause(copy)
        await #expect(throws: OperationError.self) { try await center.undo(renamed) }
        #expect(await center.snapshots().first { $0.id == renamed }?.canUndo == true)

        await center.cancel(copy)
        await center.waitUntilIdle()
        try await center.undo(renamed)
        await center.waitUntilIdle()
        #expect(source.exists("a.txt") && !source.exists("b.txt"))
    }
}
