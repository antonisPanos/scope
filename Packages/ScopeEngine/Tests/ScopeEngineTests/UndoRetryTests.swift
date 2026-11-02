import Foundation
import Testing

@testable import ScopeEngine

@Suite(.serialized) struct UndoRetryTests {
    @Test func aPartlyAppliedUndoRetriesOnlyItsRemainingSteps() async throws {
        let disk = try TestVolume(name: "ScopeUndoRetry")
        let engine = FileEngine(pathGuard: .restricted(to: [disk.mountPoint]))
        let center = OperationCenter(engine: engine) { _ in (.stop, false) }
        try disk.write("a.txt", "a")
        try disk.write("b.txt", "b")
        let trashed = try await center.enqueue(FileOperation(.trash([disk.url("a.txt"), disk.url("b.txt")])))
        await center.waitUntilIdle()
        try disk.write("a.txt", "blocking replacement")
        let attempt = try #require(try await center.undo(trashed))
        await center.waitUntilIdle()
        #expect(await center.snapshots().first { $0.id == attempt }?.progress.itemsDone == 1)
        #expect(await center.snapshots().first { $0.id == trashed }?.canUndo == true)
        #expect(try disk.read("b.txt") == "b")
        #expect(try disk.read("a.txt") == "blocking replacement")

        try FileManager.default.moveItem(at: disk.url("a.txt"), to: disk.url("saved.txt"))
        let retry = try #require(try await center.undo(trashed))
        await center.waitUntilIdle()
        #expect(await center.snapshots().first { $0.id == retry }?.state == .done)
        #expect(try disk.read("a.txt") == "a")
        #expect(try disk.read("b.txt") == "b")
        #expect(try disk.read("saved.txt") == "blocking replacement")
        #expect(await center.snapshots().first { $0.id == trashed }?.canUndo == false)
    }

    @Test func cancellingAQueuedUndoLeavesTheOperationUndoable() async throws {
        let disk = try TestVolume(name: "ScopeQueuedUndo")
        let source = try TestVolume(name: "ScopeUndoSource")
        let engine = FileEngine(pathGuard: .restricted(to: [disk.mountPoint, source.mountPoint]))
        let center = OperationCenter(engine: engine) { _ in (.stop, false) }
        try disk.write("a.txt", "a")
        try source.write("big.bin", Data(count: 96 * 1024 * 1024))
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let renamed = try await center.enqueue(FileOperation(.rename(disk.url("a.txt"), to: "b.txt")))
        await center.waitUntilIdle()
        let copy = try await center.enqueue(FileOperation(.copy([source.url("big.bin")], into: disk.url("dest"))))
        await center.pause(copy)
        let undo = try #require(try await center.undo(renamed))
        #expect(await center.snapshots().first { $0.id == undo }?.state == .queued)
        await center.cancel(undo)
        #expect(await center.snapshots().first { $0.id == renamed }?.canUndo == true)
        await center.cancel(copy)
        await center.waitUntilIdle()
        let retry = try #require(try await center.undo(renamed))
        await center.waitUntilIdle()
        #expect(await center.snapshots().first { $0.id == retry }?.state == .done)
        #expect(try disk.read("a.txt") == "a")
    }
}
