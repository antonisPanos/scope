import Darwin
import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCOPE_BOUNDED_ROOT"] != nil))
struct BoundedCopyStrategyTests {
    @Test func unsupportedCloneFallsBackToVerifiedByteCopy() async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("source", count: 384)
        let destination = fixture.root.appendingPathComponent("destination")
        let cloneAttempts = Mutex(0)
        fixture.engine.copyTestOptions.disableCloning = false
        fixture.engine.copyTestOptions.cloneFault = { _ in
            cloneAttempts.withLock { $0 += 1 }
            return ENOTSUP
        }
        let undo = UndoRecorder()
        try await fixture.engine.run(
            FileOperation(.copy([source], into: destination)), control: OperationControl(), undo: undo,
            resolveConflict: { _ in (.stop, false) })
        #expect(cloneAttempts.withLock { $0 } == 1)
        #expect(try Data(contentsOf: destination.appendingPathComponent("source")) == Data(contentsOf: source))
        #expect(undo.recorded.count == 1)
        try fixture.checkBudget()
    }

    @Test func shortWritesPublishCompleteContent() async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("source", count: 384)
        let destination = fixture.root.appendingPathComponent("destination")
        let attempts = Mutex<[Int64]>([])
        fixture.engine.copyTestOptions.writeLimit = { offset, remaining in
            attempts.withLock { $0.append(offset) }
            return min(remaining, 7)
        }
        let undo = UndoRecorder()
        try await fixture.engine.run(
            FileOperation(.copy([source], into: destination)), control: OperationControl(), undo: undo,
            resolveConflict: { _ in (.stop, false) })
        let offsets = attempts.withLock { $0 }
        #expect(offsets.count >= 54)
        #expect(offsets.first == 0)
        #expect(offsets.allSatisfy { $0 >= 0 && $0 < 384 })
        #expect(try Data(contentsOf: destination.appendingPathComponent("source")) == Data(contentsOf: source))
        #expect(undo.recorded.count == 1)
        try fixture.checkBudget()
    }

    @Test func shortWritesThenNoSpaceLeaveNoPublishedCopy() async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("source", count: 384)
        let destination = fixture.root.appendingPathComponent("destination")
        let attempts = Mutex(0)
        fixture.engine.copyTestOptions.writeLimit = { _, remaining in
            attempts.withLock { $0 += 1 }
            return min(remaining, 7)
        }
        fixture.engine.writeFault = { _, offset in offset >= 128 ? ENOSPC : nil }
        let undo = UndoRecorder()
        await #expect(throws: (any Error).self) {
            try await fixture.engine.run(
                FileOperation(.copy([source], into: destination)), control: OperationControl(), undo: undo,
                resolveConflict: { _ in (.stop, false) })
        }
        #expect(attempts.withLock { $0 } >= 18)
        #expect(try Data(contentsOf: source) == Data(repeating: 0x61, count: 384))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(undo.recorded.isEmpty)
        try fixture.checkBudget()
    }
}
