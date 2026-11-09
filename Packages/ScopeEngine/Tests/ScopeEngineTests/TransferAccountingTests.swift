import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

@Suite(.serialized) struct TransferAccountingTests {
    @Test func skippedFolderRemovesItsDescendantsFromPendingTotals() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("source/folder/a", "abc")
        try sandbox.write("source/folder/nested/b", "de")
        try sandbox.write("destination/folder/existing", "keep")
        try sandbox.write("source/other", "ok")
        let control = OperationControl()
        let undo = UndoRecorder()
        try await sandbox.engine.run(
            FileOperation(
                .copy(
                    [sandbox.url("source/folder"), sandbox.url("source/other")],
                    into: sandbox.url("destination"))),
            control: control, undo: undo, resolveConflict: { _ in (.skip, false) })
        #expect(control.progress.bytesDone == 2)
        #expect(control.progress.bytesTotal == 2)
        #expect(control.progress.itemsDone == 1)
        #expect(control.progress.itemsTotal == 1)
        #expect(sandbox.exists("source/folder/nested/b"))
        #expect(sandbox.exists("destination/folder/existing"))
        #expect(undo.recorded.count == 1)
        let report = try #require(control.transferReport)
        #expect(report.skippedCount == 1)
        #expect(report.outcomes.count == 2)
        #expect(report.outcomes[0].items == 4)
        #expect(report.outcomes[1].result == .completed)
        #expect(report.transferredBytes == 2)
    }

    @Test func allSkippedHasNoClaimedCopiedBytes() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("source/a", "incoming")
        try sandbox.write("destination/a", "existing")
        let sameDate = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: sameDate], ofItemAtPath: sandbox.url("source/a").path)
        try FileManager.default.setAttributes(
            [.modificationDate: sameDate], ofItemAtPath: sandbox.url("destination/a").path)
        let control = OperationControl()
        try await sandbox.engine.run(
            FileOperation(.copy([sandbox.url("source/a")], into: sandbox.url("destination"))),
            control: control, undo: UndoRecorder(), resolveConflict: { _ in (.replaceIfOlder, false) })
        #expect(control.progress.bytesDone == 0)
        #expect(control.progress.bytesTotal == 0)
        #expect(control.progress.itemsDone == 0)
        #expect(control.progress.itemsTotal == 0)
    }

    @Test func failureSkipAllKeepsSourcesAndCountsOnlySuccessfulWork() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("source/one/bad", "one")
        try sandbox.write("source/two/bad", "two")
        try sandbox.write("source/good", "ok")
        try sandbox.mkdir("destination")
        var engine = sandbox.engine
        engine.readFault = { path in path.hasSuffix("/bad") ? EIO : nil }
        let asked = Mutex(0)
        let control = OperationControl()
        let undo = UndoRecorder()
        try await engine.run(
            FileOperation(
                .copy(
                    [sandbox.url("source/one"), sandbox.url("source/two"), sandbox.url("source/good")],
                    into: sandbox.url("destination"))),
            control: control, undo: undo, resolveConflict: { _ in (.stop, false) },
            resolveFailure: { _ in
                asked.withLock { $0 += 1 }
                return (.skip, true)
            })
        #expect(asked.withLock { $0 } == 1)
        #expect(control.progress.bytesDone == 2)
        #expect(control.progress.bytesTotal == 2)
        #expect(control.progress.itemsDone == 1)
        #expect(control.progress.itemsTotal == 1)
        #expect(sandbox.exists("source/one/bad"))
        #expect(sandbox.exists("source/two/bad"))
        #expect(!sandbox.exists("destination/one"))
        #expect(!sandbox.exists("destination/two"))
        #expect(undo.recorded.count == 1)
        let report = try #require(control.transferReport)
        #expect(report.skippedCount == 2)
        for outcome in report.outcomes.prefix(2) {
            guard case .failedAndSkipped(let reason) = outcome.result else {
                Issue.record("Expected an I/O failure skip")
                continue
            }
            #expect(!reason.isEmpty)
        }
    }

    @Test func retryDoesNotDoubleCountAnAttempt() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("source/file", "hello")
        try sandbox.mkdir("destination")
        var engine = sandbox.engine
        let failuresLeft = Mutex(1)
        engine.readFault = { _ in
            failuresLeft.withLock { left in
                guard left > 0 else { return nil }
                left -= 1
                return EIO
            }
        }
        let control = OperationControl()
        try await engine.run(
            FileOperation(.copy([sandbox.url("source/file")], into: sandbox.url("destination"))),
            control: control, undo: UndoRecorder(), resolveConflict: { _ in (.stop, false) },
            resolveFailure: { _ in (.retry, false) })
        #expect(control.progress.bytesDone == 5)
        #expect(control.progress.bytesTotal == 5)
        #expect(control.transferReport?.transferredBytes == 5)
        #expect(control.transferReport?.outcomes.count == 1)
        #expect(control.transferReport?.outcomes.first?.result == .completed)
    }

    @Test func stoppingAfterFirstItemReportsRemainingUntouched() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("source/a", "a")
        try sandbox.write("source/b", "b")
        try sandbox.write("source/c", "c")
        try sandbox.write("destination/b", "existing")
        let control = OperationControl()
        await #expect(throws: OperationError.stoppedByUser) {
            try await sandbox.engine.run(
                FileOperation(
                    .copy(
                        [sandbox.url("source/a"), sandbox.url("source/b"), sandbox.url("source/c")],
                        into: sandbox.url("destination"))),
                control: control, undo: UndoRecorder(), resolveConflict: { _ in (.stop, false) })
        }
        let report = try #require(control.transferReport)
        #expect(report.outcomes.count == 2)
        #expect(report.outcomes[0].result == .completed)
        #expect(report.notStarted == 1)
        #expect(!sandbox.exists("destination/c"))
        #expect(sandbox.exists("source/c"))
    }

    @Test func reportLimitStopsBeforeReservingAnotherItem() throws {
        let control = OperationControl()
        control.beginTransferReport()
        for index in 0..<TransferReport.maxOutcomes {
            let item = URL(fileURLWithPath: "/test/\(index)")
            try control.reserveOutcome(for: item, remaining: 1)
            control.recordOutcome(TransferOutcome(item: item, items: 1, bytes: 0, result: .completed))
        }
        #expect(throws: OperationError.transferReportLimit(3)) {
            try control.reserveOutcome(for: URL(fileURLWithPath: "/test/next"), remaining: 3)
        }
        let report = try #require(control.transferReport)
        #expect(report.outcomes.count == TransferReport.maxOutcomes)
        #expect(report.notStarted == 3)
    }

    @Test func reportTextBudgetStopsBeforeAnOversizedItem() throws {
        let control = OperationControl()
        control.beginTransferReport()
        let item = URL(fileURLWithPath: "/" + String(repeating: "a", count: TransferReport.maxTextBytes))
        #expect(throws: OperationError.transferReportLimit(2)) {
            try control.reserveOutcome(for: item, remaining: 2)
        }
        #expect(control.transferReport?.outcomes.isEmpty == true)
        #expect(control.transferReport?.notStarted == 2)
    }

    @Test func batchLimitLeavesNextItemUntouched() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("source/a", "a")
        try sandbox.write("source/b", "b")
        try sandbox.mkdir("destination")
        let control = OperationControl(reportOutcomeLimit: 1)
        let undo = UndoRecorder()
        await #expect(throws: OperationError.transferReportLimit(1)) {
            try await sandbox.engine.run(
                FileOperation(
                    .copy(
                        [sandbox.url("source/a"), sandbox.url("source/b")],
                        into: sandbox.url("destination"))),
                control: control, undo: undo, resolveConflict: { _ in (.stop, false) })
        }
        #expect(sandbox.exists("destination/a"))
        #expect(!sandbox.exists("destination/b"))
        #expect(sandbox.exists("source/b"))
        #expect(undo.recorded.count == 1)
        #expect(control.transferReport?.notStarted == 1)
        #expect(control.transferReport?.outcomes.count == 1)
    }
}
