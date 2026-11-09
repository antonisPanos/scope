import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCOPE_BOUNDED_ROOT"] != nil))
struct MergeFoundationTests {
    @Test func eligibilityRejectsLinksPackagesAndMissingItems() throws {
        let fixture = try BoundedFixture()
        let folder = fixture.root.appendingPathComponent("ordinary")
        let package = fixture.root.appendingPathComponent("example.app")
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        #expect(FileEngine.mergeEligible(folder, folder))
        #expect(!FileEngine.mergeEligible(folder, package))
        #expect(!FileEngine.mergeEligible(folder, link))
        #expect(!FileEngine.mergeEligible(folder, fixture.root.appendingPathComponent("missing")))
        try fixture.checkBudget()
    }

    @Test func mergeChoiceIsNotReusedForIneligibleFolders() async throws {
        let count = Mutex(0)
        var policy = ConflictPolicy { _ in
            let current = count.withLock { value in value += 1; return value }
            return current == 1 ? (.merge, true) : (.skip, false)
        }
        let url = URL(fileURLWithPath: "/folder")
        let eligible = Conflict(incoming: url, existing: url, incomingKind: .directory, existingKind: .directory, canMerge: true)
        let ineligible = Conflict(incoming: url, existing: url, incomingKind: .directory, existingKind: .directory)
        #expect(try await policy.resolve(eligible) == .merge)
        #expect(try await policy.resolve(ineligible) == .skip)
        #expect(count.withLock { $0 } == 2)
    }

    @Test func nestedReservationsCountBeforeRecording() throws {
        let control = OperationControl(reportOutcomeLimit: 2)
        control.beginTransferReport()
        let parent = URL(fileURLWithPath: "/parent")
        let child = parent.appendingPathComponent("child")
        try control.reserveOutcome(for: parent, remaining: 1)
        try control.reserveOutcome(for: child, remaining: 1)
        #expect(throws: (any Error).self) {
            try control.reserveOutcome(for: child.appendingPathComponent("other"), remaining: 1)
        }
        control.recordOutcome(TransferOutcome(item: child, items: 1, bytes: 0, result: .completed))
        control.recordOutcome(TransferOutcome(item: parent, items: 1, bytes: 0, result: .completed))
        #expect(control.transferReport?.outcomes.count == 2)
    }
}
