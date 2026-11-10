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
            let current = count.withLock { value in
                value += 1
                return value
            }
            return current == 1 ? (.merge, true) : (.skip, false)
        }
        let url = URL(fileURLWithPath: "/folder")
        let eligible = Conflict(
            incoming: url, existing: url, incomingKind: .directory, existingKind: .directory, canMerge: true)
        let ineligible = Conflict(incoming: url, existing: url, incomingKind: .directory, existingKind: .directory)
        #expect(try await policy.resolve(eligible) == .merge)
        #expect(try await policy.resolve(ineligible) == .skip)
        #expect(count.withLock { $0 } == 2)
    }

    @Test func nestedOutcomesAreCountedPastTheListLimit() throws {
        let control = OperationControl(reportOutcomeLimit: 1)
        control.beginTransferReport()
        let parent = URL(fileURLWithPath: "/parent")
        let child = parent.appendingPathComponent("child")
        control.recordOutcome(TransferOutcome(item: child, items: 1, bytes: 0, result: .completed))
        control.recordOutcome(
            TransferOutcome(item: parent, items: 1, bytes: 0, result: .incomplete("Some children were skipped")))
        let report = try #require(control.transferReport)
        #expect(report.outcomes.map(\.item) == [parent])
        #expect(report.unlistedCount == 1)
        #expect(report.skippedCount == 0)
        #expect(report.hasProblems)
    }

    @Test func pinnedDirectoryRejectsReplacement() throws {
        let fixture = try BoundedFixture()
        let directory = fixture.root.appendingPathComponent("folder")
        let original = fixture.root.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let guarder = PathGuard.restricted(to: [fixture.root])
        let pinned = try MergeDirectory(directory, pathGuard: guarder, writable: true)
        try FileManager.default.moveItem(at: directory, to: original)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try pinned.validate(pathGuard: guarder) }
        try fixture.checkBudget()
    }
}
