import Darwin
import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

/// Selected only by scripts/test-bounded.py, which supplies the owned root
/// and confines the whole test process. The normal suite retains integration coverage.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCOPE_BOUNDED_ROOT"] != nil))
struct BoundedFaultTests {

    @Test func writeFailureKeepsSourceAndRemovesPartial() async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("source", count: 384)
        let destination = fixture.root.appendingPathComponent("destination")
        fixture.engine.writeFault = { _, offset in offset >= 128 ? ENOSPC : nil }
        let undo = UndoRecorder()
        await #expect(throws: (any Error).self) {
            try await fixture.engine.run(
                FileOperation(.copy([source], into: destination)),
                control: OperationControl(), undo: undo, resolveConflict: { _ in (.stop, false) })
        }
        #expect(try Data(contentsOf: source).count == 384)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(undo.recorded.isEmpty)
        try fixture.checkBudget()
    }

    @Test func simulatedMoveRequiresPrivateTrash() async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("source", count: 4)
        var unsafe = fixture.engine
        unsafe.trash = .system
        let unsafeEngine = unsafe
        await #expect(throws: (any Error).self) {
            try await unsafeEngine.run(
                FileOperation(.move([source], into: fixture.root.appendingPathComponent("destination"))),
                control: OperationControl(), undo: UndoRecorder(), resolveConflict: { _ in (.stop, false) })
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        try fixture.checkBudget()
    }

    @Test func boundedProcessRefusesSystemTrash() async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("source", count: 4)
        var configured = fixture.engine
        configured.trash = .system
        let engine = configured
        await #expect(throws: (any Error).self) { try await engine.trashItem(at: source) }
        #expect(FileManager.default.fileExists(atPath: source.path))
        try fixture.checkBudget()
    }

    @Test func simulatedMoveUsesPrivateTrashAndRecordsUndo() async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("source", count: 384)
        let destination = fixture.root.appendingPathComponent("destination")
        let undo = UndoRecorder()
        try await fixture.engine.run(
            FileOperation(.move([source], into: destination)),
            control: OperationControl(), undo: undo, resolveConflict: { _ in (.stop, false) })
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: destination.appendingPathComponent("source")).count == 384)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).count == 1)
        #expect(undo.recorded.count == 2)
        try fixture.checkBudget()
    }

    @Test func insufficientCapacityFailsBeforeWriting() async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("source", count: 384)
        fixture.engine.copyTestOptions.destinationLimits = .init(
            fileSystem: "msdos", volumeName: "fixture", freeBytes: 1)
        let destination = fixture.root.appendingPathComponent("destination")
        let engine = fixture.engine
        let undo = UndoRecorder()
        await #expect(throws: OperationError.notEnoughSpace(needed: 384, available: 1, volume: "fixture")) {
            try await engine.run(
                FileOperation(.copy([source], into: destination)),
                control: OperationControl(), undo: undo, resolveConflict: { _ in (.stop, false) })
        }
        #expect(try Data(contentsOf: source).count == 384)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(undo.recorded.isEmpty)
        try fixture.checkBudget()
    }

    @Test func retryAfterReadErrorCopiesOriginal() async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("source", count: 384)
        let destination = fixture.root.appendingPathComponent("destination")
        let failures = Mutex(0)
        fixture.engine.readFault = { _ in
            failures.withLock { count in
                count += 1
                return count == 1 ? EIO : nil
            }
        }
        let engine = fixture.engine
        let undo = UndoRecorder()
        try await engine.run(
            FileOperation(.copy([source], into: destination)), control: OperationControl(), undo: undo,
            resolveConflict: { _ in (.stop, false) }, resolveFailure: { _ in (.retry, false) })
        #expect(try Data(contentsOf: source) == Data(contentsOf: destination.appendingPathComponent("source")))
        #expect(failures.withLock { $0 } == 2)
        #expect(undo.recorded.count == 1)
        try fixture.checkBudget()
    }

    @Test func boundaryHooksObserveMoveLifecycle() async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("source", count: 384)
        let events = Mutex<[FileEngine.CopyBoundary]>([])
        fixture.engine.copyTestOptions.boundary = { event, _, _ in events.withLock { $0.append(event) } }
        let engine = fixture.engine
        try await engine.run(
            FileOperation(.move([source], into: fixture.root.appendingPathComponent("destination"))),
            control: OperationControl(), undo: UndoRecorder(), resolveConflict: { _ in (.stop, false) })
        #expect(
            events.withLock { $0 } == [
                .beforeMetadata, .beforeVerification, .afterVerification,
                .beforePublication, .beforeSync, .beforeSourceRetirement,
            ])
        try fixture.checkBudget()
    }

    @Test func boundedProcessRefusesDiskToolEntry() async throws {
        await #expect(throws: (any Error).self) {
            try await FileEngine.runTool("/usr/sbin/diskutil", ["list"], input: nil, timeout: 1)
        }
    }

    @Test func cancellationBetweenChunksKeepsSourceAndCleansStaging() async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("source", count: 384)
        let destination = fixture.root.appendingPathComponent("destination")
        let handle = Mutex<Task<Void, Error>?>(nil)
        fixture.engine.writeFault = { _, offset in
            if offset >= 128 { handle.withLock { $0?.cancel() } }
            return nil
        }
        let engine = fixture.engine
        let undo = UndoRecorder()
        let gate = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            for await _ in gate.stream { break }
            try await engine.run(
                FileOperation(.copy([source], into: destination)),
                control: OperationControl(), undo: undo, resolveConflict: { _ in (.stop, false) })
        }
        handle.withLock { $0 = task }
        gate.continuation.yield(())
        gate.continuation.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: source).count == 384)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(undo.recorded.isEmpty)
        try fixture.checkBudget()
    }
}
