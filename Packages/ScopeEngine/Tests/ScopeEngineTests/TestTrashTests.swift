import Foundation
import Testing

@testable import ScopeEngine

/// A sandbox's engine trashes into a folder of the test's own, so Trash and
/// undo can be tested anywhere, CI included, without reaching a real Trash.
struct TestTrashTests {
    let sandbox: Sandbox
    let ops: OperationHarness

    init() throws {
        sandbox = try Sandbox()
        ops = OperationHarness(engine: sandbox.engine)
    }

    @Test func trashedItemsGoToTheTestsOwnTrash() async throws {
        try sandbox.write("a.txt", "a")
        let trashed = try #require(try await sandbox.engine.trashItem(at: sandbox.url("a.txt")))
        #expect(trashed.deletingLastPathComponent().path == sandbox.trash.path)
        #expect(try String(contentsOf: trashed, encoding: .utf8) == "a")
        #expect(!sandbox.exists("a.txt"))
    }

    @Test func trashAndUndoPutsItemsBack() async throws {
        try sandbox.write("a.txt", "a")
        try sandbox.write("folder/b.txt", "b")
        let record = try await ops.run(.trash([sandbox.url("a.txt"), sandbox.url("folder")]))
        #expect(try sandbox.names() == [])
        try await ops.undo(record)
        #expect(try sandbox.names() == ["a.txt", "folder"])
        #expect(try sandbox.names(in: "folder") == ["b.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.trash.path).isEmpty)
    }

    @Test func undoingADuplicateTrashesTheCopy() async throws {
        try sandbox.write("a.txt", "a")
        let record = try await ops.run(.duplicate([sandbox.url("a.txt")]))
        #expect(try sandbox.names() == ["a copy.txt", "a.txt"])
        try await ops.undo(record)
        #expect(try sandbox.names() == ["a.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.trash.path).count == 1)
    }

    @Test func aReplacedItemComesBackOnUndo() async throws {
        try sandbox.write("src/a.txt", "new")
        try sandbox.write("dest/a.txt", "old")
        var harness = ops
        harness.conflictAnswer = .replace
        let record = try await harness.run(.copy([sandbox.url("src/a.txt")], into: sandbox.url("dest")))
        #expect(try String(contentsOf: sandbox.url("dest/a.txt"), encoding: .utf8) == "new")
        try await harness.undo(record)
        #expect(try String(contentsOf: sandbox.url("dest/a.txt"), encoding: .utf8) == "old")
    }
}
