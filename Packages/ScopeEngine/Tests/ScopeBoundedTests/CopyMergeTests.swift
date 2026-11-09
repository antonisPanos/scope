import Foundation
import Testing

@testable import ScopeEngine

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCOPE_BOUNDED_ROOT"] != nil))
struct CopyMergeTests {
    private func folders(_ fixture: BoundedFixture) throws -> (URL, URL) {
        let source = fixture.root.appendingPathComponent("folder")
        let target = fixture.root.appendingPathComponent("destination/folder")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return (source, target)
    }

    @Test func copiesChildrenAndUndoPreservesExistingContent() async throws {
        let fixture = try BoundedFixture()
        let (source, target) = try folders(fixture)
        try Data("new".utf8).write(to: source.appendingPathComponent("new"))
        try Data("old".utf8).write(to: target.appendingPathComponent("old"))
        let undo = UndoRecorder()
        try await fixture.engine.run(
            FileOperation(.copy([source], into: target.deletingLastPathComponent())),
            control: OperationControl(), undo: undo, resolveConflict: { _ in (.merge, false) })
        #expect(try Data(contentsOf: target.appendingPathComponent("new")) == Data("new".utf8))
        let record = UndoRecord(title: "copy", steps: undo.recorded)
        try await fixture.engine.run(
            FileOperation(.undo(record)), control: OperationControl(),
            undo: UndoRecorder(), resolveConflict: { _ in (.stop, false) })
        #expect(try Data(contentsOf: target.appendingPathComponent("old")) == Data("old".utf8))
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("new").path))
        try fixture.checkBudget()
    }

    @Test func nestedMergeSkipReportsPartialAndPreservesDestination() async throws {
        let fixture = try BoundedFixture()
        let (source, target) = try folders(fixture)
        let nestedSource = source.appendingPathComponent("nested")
        let nestedTarget = target.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedSource, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: nestedTarget, withIntermediateDirectories: false)
        try Data("incoming".utf8).write(to: nestedSource.appendingPathComponent("same"))
        try Data("existing".utf8).write(to: nestedTarget.appendingPathComponent("same"))
        try Data("new".utf8).write(to: nestedSource.appendingPathComponent("new"))
        let control = OperationControl()
        try await fixture.engine.run(
            FileOperation(.copy([source], into: target.deletingLastPathComponent())),
            control: control, undo: UndoRecorder(),
            resolveConflict: { conflict in
                (conflict.canMerge ? .merge : .skip, false)
            })
        #expect(try Data(contentsOf: nestedTarget.appendingPathComponent("same")) == Data("existing".utf8))
        #expect(try Data(contentsOf: nestedTarget.appendingPathComponent("new")) == Data("new".utf8))
        #expect((control.transferReport?.skippedCount ?? 0) > 0)
        try fixture.checkBudget()
    }

    @Test func reportLimitStopsBeforeChildMutation() async throws {
        let fixture = try BoundedFixture()
        let (source, target) = try folders(fixture)
        try Data("x".utf8).write(to: source.appendingPathComponent("child"))
        let control = OperationControl(reportOutcomeLimit: 1)
        await #expect(throws: (any Error).self) {
            try await fixture.engine.run(
                FileOperation(.copy([source], into: target.deletingLastPathComponent())),
                control: control, undo: UndoRecorder(), resolveConflict: { _ in (.merge, false) })
        }
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("child").path))
        try fixture.checkBudget()
    }

    @Test func cancellationAtPromptDoesNotCopy() async throws {
        let fixture = try BoundedFixture()
        let (source, target) = try folders(fixture)
        try Data("x".utf8).write(to: source.appendingPathComponent("child"))
        await #expect(throws: CancellationError.self) {
            try await fixture.engine.run(
                FileOperation(.copy([source], into: target.deletingLastPathComponent())),
                control: OperationControl(), undo: UndoRecorder(),
                resolveConflict: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return (.merge, false)
                })
        }
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("child").path))
        try fixture.checkBudget()
    }

    @Test func replacedTargetIsRejectedAfterPrompt() async throws {
        let fixture = try BoundedFixture()
        let (source, target) = try folders(fixture)
        let displaced = target.deletingLastPathComponent().appendingPathComponent("displaced")
        try Data("x".utf8).write(to: source.appendingPathComponent("child"))
        await #expect(throws: (any Error).self) {
            try await fixture.engine.run(
                FileOperation(.copy([source], into: target.deletingLastPathComponent())),
                control: OperationControl(), undo: UndoRecorder(),
                resolveConflict: { _ in
                    try? FileManager.default.moveItem(at: target, to: displaced)
                    try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                    return (.merge, false)
                })
        }
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("child").path))
        try fixture.checkBudget()
    }
}
