import Darwin
import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCOPE_BOUNDED_ROOT"] != nil))
struct BoundedTransferReportTests {
    @Test func mixedOutcomesKeepEveryReasonAndOnlyCountCopiedBytes() async throws {
        let fixture = try BoundedFixture()
        let good = try fixture.write("good", count: 4)
        let conflict = try fixture.write("conflict", count: 3)
        let bad = try fixture.write("bad", count: 2)
        let destination = fixture.root.appendingPathComponent("destination")
        try Data([0x62]).write(to: destination.appendingPathComponent("conflict"))
        fixture.engine.readFault = { path in path.hasSuffix("/bad") ? EIO : nil }
        let engine = fixture.engine
        let control = OperationControl()
        let undo = UndoRecorder()
        try await engine.run(
            FileOperation(.copy([good, conflict, bad], into: destination)), control: control, undo: undo,
            resolveConflict: { _ in (.skip, false) }, resolveFailure: { _ in (.skip, true) })
        let report = try #require(control.transferReport)
        #expect(report.outcomes.count == 3)
        #expect(report.outcomes[0].result == .completed)
        guard case .skipped(let reason) = report.outcomes[1].result else {
            Issue.record("Expected a conflict skip")
            return
        }
        #expect(!reason.isEmpty)
        guard case .failedAndSkipped(let failure) = report.outcomes[2].result else {
            Issue.record("Expected a failure skip")
            return
        }
        #expect(!failure.isEmpty)
        #expect(report.skippedCount == 2)
        #expect(report.transferredBytes == 4)
        #expect(control.progress.bytesTotal == 4)
        #expect(control.progress.itemsTotal == 1)
        #expect(undo.recorded.count == 1)
        #expect(FileManager.default.fileExists(atPath: bad.path))
        try fixture.checkBudget()
    }

    @Test func retryDoesNotDoubleCount() async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("retry", count: 384)
        let failures = Mutex(0)
        fixture.engine.readFault = { _ in
            failures.withLock { count in
                count += 1
                return count == 1 ? EIO : nil
            }
        }
        let engine = fixture.engine
        let control = OperationControl()
        try await engine.run(
            FileOperation(.copy([source], into: fixture.root.appendingPathComponent("destination"))),
            control: control, undo: UndoRecorder(), resolveConflict: { _ in (.stop, false) },
            resolveFailure: { _ in (.retry, false) })
        #expect(failures.withLock { $0 } == 2)
        #expect(control.progress.bytesDone == 384)
        #expect(control.progress.itemsDone == 1)
        #expect(control.transferReport?.transferredBytes == 384)
        #expect(control.transferReport?.outcomes.count == 1)
        try fixture.checkBudget()
    }

    @Test func skippedFolderRemovesMeasuredDescendants() async throws {
        let fixture = try BoundedFixture()
        let folder = fixture.root.appendingPathComponent("folder")
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: nested.appendingPathComponent("file"))
        let destination = fixture.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let good = try fixture.write("good", count: 4)
        let control = OperationControl()
        try await fixture.engine.run(
            FileOperation(.copy([folder, good], into: destination)), control: control, undo: UndoRecorder(),
            resolveConflict: { _ in (.skip, false) })
        let report = try #require(control.transferReport)
        #expect(report.outcomes[0].items == 3)
        #expect(report.skippedCount == 1)
        #expect(control.progress.itemsDone == 1)
        #expect(control.progress.itemsTotal == 1)
        #expect(control.progress.bytesDone == 4)
        #expect(control.progress.bytesTotal == 4)
        #expect(FileManager.default.fileExists(atPath: nested.appendingPathComponent("file").path))
        try fixture.checkBudget()
    }

    @Test func countLimitKeepsCopyingAndListsTheSkip() async throws {
        let fixture = try BoundedFixture()
        let first = try fixture.write("first", count: 1)
        let conflict = try fixture.write("conflict", count: 1)
        let destination = fixture.root.appendingPathComponent("destination")
        try Data([0x62]).write(to: destination.appendingPathComponent("conflict"))
        let control = OperationControl(reportOutcomeLimit: 1)
        try await fixture.engine.run(
            FileOperation(.copy([first, conflict], into: destination)), control: control, undo: UndoRecorder(),
            resolveConflict: { _ in (.skip, false) })
        let report = try #require(control.transferReport)
        #expect(report.outcomes.count == 1)
        #expect(report.outcomes.first?.item.lastPathComponent == "conflict")
        #expect(report.unlistedCount == 1)
        #expect(report.skippedCount == 1)
        #expect(report.notStarted == 0)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("first").path))
        try fixture.checkBudget()
    }

    @Test func oversizedOutcomeIsCountedAndTheReportKept() throws {
        let control = OperationControl()
        control.beginTransferReport(notStarted: 2)
        let item = URL(fileURLWithPath: "/" + String(repeating: "a", count: TransferReport.maxTextBytes))
        control.recordOutcome(TransferOutcome(item: item, items: 1, bytes: 0, result: .completed))
        #expect(control.transferReport?.notStarted == 2)
        #expect(control.transferReport?.outcomes.isEmpty == true)
        #expect(control.transferReport?.unlistedCount == 1)
    }
}
