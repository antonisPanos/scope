import Foundation
import Testing

@testable import ScopeEngine

@Suite(.serialized) struct OperationCenterTests {
    let disk: TestVolume
    let center: OperationCenter

    init() throws {
        disk = try TestVolume(name: "ScopeQueue")
        center = OperationCenter(engine: FileEngine(pathGuard: .restricted(to: [disk.mountPoint]))) { _ in
            (.keepBoth, false)
        }
    }

    private func state(_ id: UUID) async -> OperationCenter.State? {
        await center.snapshots().first { $0.id == id }?.state
    }

    @Test func runsOperationsOnOneDiskOneAtATime() async throws {
        try disk.write("big.bin", Data(count: 32 * 1024 * 1024))
        try FileManager.default.createDirectory(at: disk.url("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disk.url("b"), withIntermediateDirectories: true)
        let first = try await center.enqueue(FileOperation(.copy([disk.url("big.bin")], into: disk.url("a"))))
        let second = try await center.enqueue(FileOperation(.newFolder(in: disk.url("b"), name: "made")))
        #expect(await state(first) == .running)
        #expect(await state(second) == .queued)
        await center.waitUntilIdle()
        #expect(await state(first) == .done)
        #expect(await state(second) == .done)
        #expect(disk.exists("a/big.bin") && disk.exists("b/made"))
    }

    @Test func refusesOperationsOnLockedItemsAndMergesRepeats() async throws {
        try disk.write("big.bin", Data(count: 64 * 1024 * 1024))
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let copy = FileOperation(.copy([disk.url("big.bin")], into: disk.url("dest")))
        let id = try await center.enqueue(copy)
        // Pressing Cmd+V again while it runs gives back the same operation.
        #expect(try await center.enqueue(copy) == id)
        // Trashing the file being copied is refused.
        await #expect(throws: OperationError.self) {
            try await center.enqueue(FileOperation(.trash([disk.url("big.bin")])))
        }
        await center.waitUntilIdle()
        #expect(await center.snapshots().count == 1)
    }

    @Test func pausesResumesAndCancels() async throws {
        try disk.write("big.bin", Data(count: 96 * 1024 * 1024))
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let id = try await center.enqueue(FileOperation(.copy([disk.url("big.bin")], into: disk.url("dest"))))
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
        try disk.write("big.bin", Data(count: 32 * 1024 * 1024))
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let running = try await center.enqueue(FileOperation(.copy([disk.url("big.bin")], into: disk.url("dest"))))
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
}
