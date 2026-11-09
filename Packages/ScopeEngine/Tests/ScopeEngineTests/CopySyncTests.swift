import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

@Suite struct CopySyncTests {
    @Test func directorySyncClassifiesFailuresAndRetriesInterruptions() throws {
        let attempts = Mutex(0)
        #expect(throws: FileEngineError.self) {
            try CopySync.sync(-1, path: "fixture", point: .directory) { _, _ in
                attempts.withLock { count in
                    count += 1
                    return count == 1 ? EINTR : EIO
                }
            }
        }
        #expect(attempts.withLock { $0 } == 2)
        try CopySync.sync(-1, path: "fixture", point: .directory) { _, _ in ENOTSUP }
        try CopySync.sync(-1, path: "fixture", point: .parent) { _, _ in EINVAL }
        #expect(throws: FileEngineError.self) {
            try CopySync.sync(-1, path: "fixture", point: .file) { _, _ in EINVAL }
        }
    }

    @Test func publicCopyReportsPublishedDestination() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("source", "new")
        let target = sandbox.url("target")
        var engine = sandbox.engine
        engine.copySyncFault = { point, _ in point == .parent ? EIO : nil }
        do {
            try await engine.copyItem(at: source, to: target)
            Issue.record("Finalization should fail")
        } catch let error as PublishedCopyFinalizationError {
            #expect(error.destination == target)
            #expect(error.publishedIdentity.inode == FileEngine.fileID(target).inode)
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "new")
        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
    }

    @Test func replacementFinalizationFailureKeepsUndoAndDoesNotRetry() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("source/item", "new")
        let target = try sandbox.write("dest/item", "old")
        var engine = sandbox.engine
        engine.copySyncFault = { point, _ in point == .parent ? EIO : nil }
        let failures = Mutex(0)
        let undo = UndoRecorder()
        await #expect(throws: PublishedCopyFinalizationError.self) {
            try await engine.run(
                FileOperation(.copy([source], into: target.deletingLastPathComponent())),
                control: OperationControl(), undo: undo, resolveConflict: { _ in (.replace, false) },
                resolveFailure: { _ in
                    failures.withLock { $0 += 1 }
                    return (.retry, false)
                })
        }
        #expect(failures.withLock { $0 } == 0)
        #expect(try String(contentsOf: source, encoding: .utf8) == "new")
        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        let steps = undo.recorded
        #expect(steps.count == 2)
        guard steps.count == 2, case .putBack(let old, let original) = steps[0],
            case .trashCreated(let created, _) = steps[1]
        else {
            Issue.record("Expected replacement and published-copy undo steps")
            return
        }
        #expect(original == target && created == target)
        #expect(try String(contentsOf: old, encoding: .utf8) == "old")
        try await engine.run(
            FileOperation(.undo(UndoRecord(title: "copy", steps: steps))),
            control: OperationControl(), undo: UndoRecorder(), resolveConflict: { _ in (.stop, false) })
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
    }

    @Test func duplicateFinalizationFailureIsUndoable() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("item.txt", "new")
        var engine = sandbox.engine
        engine.copySyncFault = { point, _ in point == .parent ? EIO : nil }
        let undo = UndoRecorder()
        await #expect(throws: PublishedCopyFinalizationError.self) {
            try await engine.run(
                FileOperation(.duplicate([source])), control: OperationControl(), undo: undo,
                resolveConflict: { _ in (.stop, false) })
        }
        #expect(sandbox.exists("item copy.txt"))
        #expect(undo.recorded.count == 1)
        try await engine.run(
            FileOperation(.undo(UndoRecord(title: "duplicate", steps: undo.recorded))),
            control: OperationControl(), undo: UndoRecorder(), resolveConflict: { _ in (.stop, false) })
        #expect(!sandbox.exists("item copy.txt"))
        #expect(sandbox.exists("item.txt"))
    }

    @Test func operationCenterReportsPublishedCopyAsFailedAndUndoable() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("source/item", "new")
        try sandbox.mkdir("dest")
        var engine = sandbox.engine
        engine.copySyncFault = { point, _ in point == .openParent ? EIO : nil }
        let center = OperationCenter(engine: engine, resolveConflict: { _ in (.stop, false) })
        let id = try await center.enqueue(FileOperation(.copy([source], into: sandbox.url("dest"))))
        await center.waitUntilIdle()
        let snapshot = try #require(await center.snapshots().first { $0.id == id })
        guard case .failed(let message) = snapshot.state else {
            Issue.record("Expected a failed operation")
            return
        }
        #expect(message.contains("published"))
        #expect(snapshot.canUndo)
        #expect(sandbox.exists("source/item") && sandbox.exists("dest/item"))
    }

    @Test func replacedPublishedCopyIsNeverTrashedByUndo() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("source/item", "new")
        try sandbox.mkdir("dest")
        let target = sandbox.url("dest/item")
        let moved = sandbox.url("dest/owned-copy")
        let swapped = Mutex(false)
        var engine = sandbox.engine
        engine.copySyncFault = { point, _ in
            guard point == .parent else { return nil }
            do {
                try FileManager.default.moveItem(at: target, to: moved)
                try Data("unrelated".utf8).write(to: target)
                swapped.withLock { $0 = true }
            } catch {}
            return EIO
        }
        let undo = UndoRecorder()
        await #expect(throws: PublishedCopyFinalizationError.self) {
            try await engine.run(
                FileOperation(.copy([source], into: target.deletingLastPathComponent())),
                control: OperationControl(), undo: undo, resolveConflict: { _ in (.stop, false) })
        }
        #expect(swapped.withLock { $0 })
        guard case .trashCreated(_, let identity) = try #require(undo.recorded.first) else {
            Issue.record("Expected published-copy undo step")
            return
        }
        #expect(identity.inode == FileEngine.fileID(moved).inode)
        #expect(identity.inode != FileEngine.fileID(target).inode)
        await #expect(throws: OperationError.self) {
            try await engine.run(
                FileOperation(.undo(UndoRecord(title: "copy", steps: undo.recorded, includesChangedItems: true))),
                control: OperationControl(), undo: UndoRecorder(), resolveConflict: { _ in (.stop, false) })
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "unrelated")
    }
}
