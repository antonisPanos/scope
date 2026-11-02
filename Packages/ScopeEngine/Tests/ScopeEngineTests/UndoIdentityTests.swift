import Foundation
import Testing

@testable import ScopeEngine

@Suite(.serialized) struct UndoIdentityTests {
    @Test(arguments: [false, true]) func undoKeepsAnUnrelatedReplacement(moving: Bool) async throws {
        let disk = try TestVolume(name: "ScopeUndoIdentity")
        let engine = FileEngine(pathGuard: .restricted(to: [disk.mountPoint]))
        let ops = OperationHarness(engine: engine)
        try disk.write("original.txt", "original")
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let kind: FileOperation.Kind =
            moving
            ? .move([disk.url("original.txt")], into: disk.url("dest"))
            : .rename(disk.url("original.txt"), to: "renamed.txt")
        let target = moving ? "dest/original.txt" : "renamed.txt"
        let record = try await ops.run(kind)
        try FileManager.default.moveItem(at: disk.url(target), to: disk.url("saved.txt"))
        try disk.write(target, "unrelated replacement")
        let before = try TreeSnapshot(disk.work)
        await #expect(throws: OperationError.self) { try await ops.undo(record) }
        #expect(try TreeSnapshot(disk.work) == before)

        // Restoring the original object makes the same record safe to retry.
        try FileManager.default.removeItem(at: disk.url(target))
        try FileManager.default.moveItem(at: disk.url("saved.txt"), to: disk.url(target))
        try await ops.undo(record)
        #expect(try disk.read("original.txt") == "original")
    }

    @Test func movingBackTheSameFilePreservesItsNewEdits() async throws {
        let disk = try TestVolume(name: "ScopeUndoEdits")
        let engine = FileEngine(pathGuard: .restricted(to: [disk.mountPoint]))
        let ops = OperationHarness(engine: engine)
        try disk.write("original.txt", "original")
        let record = try await ops.run(.rename(disk.url("original.txt"), to: "renamed.txt"))
        let handle = try FileHandle(forWritingTo: disk.url("renamed.txt"))
        try handle.write(contentsOf: Data("edited".utf8))
        try handle.close()
        let edited = try disk.read("renamed.txt")
        try await ops.undo(record)
        #expect(try disk.read("original.txt") == edited)
    }
}
