import Darwin
import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCOPE_BOUNDED_ROOT"] != nil))
struct BoundedCopySyncTests {
    @Test func failedMoveReplacementRetainsSourceAndSupportsUndo() async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("item", count: 12)
        let destination = fixture.root.appendingPathComponent("destination")
        let target = destination.appendingPathComponent("item")
        try Data("old".utf8).write(to: target)
        let retries = Mutex(0)
        let events = Mutex<[FileEngine.CopyBoundary]>([])
        fixture.engine.copySyncFault = { point, _ in point == .parent ? EIO : nil }
        fixture.engine.copyTestOptions.boundary = { point, _, _ in events.withLock { $0.append(point) } }
        let center = OperationCenter(
            engine: fixture.engine, resolveConflict: { _ in (.replace, false) },
            resolveFailure: { _ in
                retries.withLock { $0 += 1 }
                return (.retry, false)
            })
        let id = try await center.enqueue(FileOperation(.move([source], into: destination)))
        await center.waitUntilIdle()
        let snapshot = try #require(await center.snapshots().first { $0.id == id })
        guard case .failed(let message) = snapshot.state else {
            Issue.record("Expected finalization failure")
            return
        }
        #expect(message.contains("source was kept"))
        #expect(snapshot.canUndo)
        #expect(retries.withLock { $0 } == 0)
        #expect(events.withLock { $0.contains(.beforeSync) && !$0.contains(.beforeSourceRetirement) })
        #expect(try Data(contentsOf: source) == Data(repeating: 0x61, count: 12))
        #expect(try Data(contentsOf: target) == Data(contentsOf: source))
        let trashNames = try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path)
        #expect(trashNames.count == 1)
        let oldName = try #require(trashNames.first)
        #expect(try Data(contentsOf: fixture.trash.appendingPathComponent(oldName)) == Data("old".utf8))
        let undoID = try #require(await center.undo(id))
        await center.waitUntilIdle()
        let undoState = try #require(await center.snapshots().first { $0.id == undoID })
        #expect(undoState.state == .done)
        #expect(try Data(contentsOf: target) == Data("old".utf8))
        #expect(try Data(contentsOf: source) == Data(repeating: 0x61, count: 12))
        try fixture.checkBudget()
    }

    @Test func moveReplacementRecordsBothUndoStepsBeforeReportingFailure() async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("item", count: 12)
        let destination = fixture.root.appendingPathComponent("destination")
        let target = destination.appendingPathComponent("item")
        try Data("old".utf8).write(to: target)
        fixture.engine.copySyncFault = { point, _ in point == .parent ? EIO : nil }
        let engine = fixture.engine
        let undo = UndoRecorder()
        await #expect(throws: OperationError.self) {
            try await engine.run(
                FileOperation(.move([source], into: destination)), control: OperationControl(), undo: undo,
                resolveConflict: { _ in (.replace, false) })
        }
        let steps = undo.recorded
        #expect(steps.count == 2)
        guard steps.count == 2, case .putBack(let old, let original) = steps[0],
            case .trashCreated(let copy, let identity) = steps[1]
        else {
            Issue.record("Expected replacement and destination undo steps")
            return
        }
        #expect(original == target && copy == target)
        #expect(identity.inode == FileEngine.fileID(target).inode)
        #expect(try Data(contentsOf: old) == Data("old".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path))
        try fixture.checkBudget()
    }

    @Test func directorySyncFailureBeforePublicationKeepsSource() async throws {
        let fixture = try BoundedFixture()
        let child = try fixture.write("child", count: 8)
        let source = fixture.root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: child, to: source.appendingPathComponent("child"))
        let destination = fixture.root.appendingPathComponent("destination")
        fixture.engine.copySyncFault = { point, _ in point == .directory ? EIO : nil }
        let engine = fixture.engine
        let undo = UndoRecorder()
        await #expect(throws: (any Error).self) {
            try await engine.run(
                FileOperation(.move([source], into: destination)), control: OperationControl(), undo: undo,
                resolveConflict: { _ in (.stop, false) })
        }
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("child").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
        #expect(undo.recorded.isEmpty)
        try fixture.checkBudget()
    }

    @Test func unsupportedDirectorySyncUsesFallback() async throws {
        let fixture = try BoundedFixture()
        let child = try fixture.write("child", count: 8)
        let source = fixture.root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: child, to: source.appendingPathComponent("child"))
        let destination = fixture.root.appendingPathComponent("destination")
        fixture.engine.copySyncFault = { point, _ in
            if point == .directory { return EINVAL }
            if point == .parent { return ENOTSUP }
            return nil
        }
        try await fixture.engine.run(
            FileOperation(.move([source], into: destination)), control: OperationControl(), undo: UndoRecorder(),
            resolveConflict: { _ in (.stop, false) })
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("folder/child").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).count == 1)
        try fixture.checkBudget()
    }
}
