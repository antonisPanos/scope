import Foundation
import ScopeEngine
import Testing

@testable import Scope

/// A failed operation is reported once, when it fails, even when it failed
/// before the activity list ever saw it running.
struct FailedOperationTests {
    private let id = UUID()

    private func failures(now: OperationCenter.State, before: OperationCenter.State?) -> [String] {
        let previous = before.map { [id: $0] } ?? [:]
        let current = [(id: id, title: "Extracting a.zip", state: now)]
        return OperationsController.newlyFailed(current, previous: previous).map(\.message)
    }

    @Test func reportsAFailureOnce() {
        #expect(failures(now: .failed("Damaged"), before: .running) == ["Damaged"])
        #expect(failures(now: .failed("Damaged"), before: .queued) == ["Damaged"])
        #expect(failures(now: .failed("Damaged"), before: .failed("Damaged")).isEmpty)
    }

    @Test func reportsAFailureTooQuickToBeSeenRunning() {
        #expect(failures(now: .failed("Not an archive"), before: nil) == ["Not an archive"])
    }

    @Test func ignoresEverythingElse() {
        #expect(failures(now: .done, before: .running).isEmpty)
        #expect(failures(now: .cancelled, before: .running).isEmpty)
        #expect(failures(now: .running, before: .queued).isEmpty)
    }
}
