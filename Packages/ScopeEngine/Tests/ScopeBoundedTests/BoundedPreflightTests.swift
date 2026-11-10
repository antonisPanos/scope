import Darwin
import Foundation
import Testing

@testable import ScopeEngine

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCOPE_BOUNDED_ROOT"] != nil))
struct BoundedPreflightTests {
    @Test(arguments: [FileEngine.DestinationLimits.Support.unsupported, .unknown])
    func incompatibleLinksStopCopiesAndMovesBeforeWriting(support: FileEngine.DestinationLimits.Support) async throws {
        let fixture = try BoundedFixture()
        let source = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "missing")
        let destination = fixture.root.appendingPathComponent("destination")
        fixture.engine.copyTestOptions.destinationLimits?.symbolicLinks = support
        let engine = fixture.engine

        for moving in [false, true] {
            let undo = UndoRecorder()
            let kind: FileOperation.Kind =
                moving ? .move([source], into: destination) : .copy([source], into: destination)
            do {
                try await engine.run(
                    FileOperation(kind), control: OperationControl(), undo: undo,
                    resolveConflict: { _ in (.stop, false) })
                Issue.record("Preflight should refuse the link")
            } catch let OperationError.incompatibleDestination(report) {
                #expect(report.totalCount == 1)
                #expect(report.entries.first?.path == "link")
                #expect(
                    report.entries.first?.reason
                        == (support == .unknown ? .symbolicLinksUnknown : .symbolicLinksUnsupported))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: source.path) == "missing")
            #expect(undo.recorded.isEmpty)
        }
        try fixture.checkBudget()
    }

    @Test func supportedLinkIsCopiedAsALink() async throws {
        let fixture = try BoundedFixture()
        let source = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "missing")
        let destination = fixture.root.appendingPathComponent("destination")
        fixture.engine.copyTestOptions.destinationLimits?.symbolicLinks = .supported
        // The operation-wide test option takes precedence over the method provider.
        try fixture.engine.preflight([source], into: destination, moving: false) { _ in
            throw CocoaError(.featureUnsupported)
        }
        let undo = UndoRecorder()
        try await fixture.engine.run(
            FileOperation(.copy([source], into: destination)), control: OperationControl(), undo: undo,
            resolveConflict: { _ in (.stop, false) })
        let copied = destination.appendingPathComponent("link")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied.path) == "missing")
        #expect(undo.recorded.count == 1)
        try fixture.checkBudget()
    }

    @Test func reportIsBoundedForARealOperation() async throws {
        let fixture = try BoundedFixture()
        let sources = try (0..<11).map { try fixture.write("bad:\($0)", count: 3) }
        let destination = fixture.root.appendingPathComponent("destination")
        var limits = FileEngine.DestinationLimits(fileSystem: "exfat", volumeName: "fixture", freeBytes: nil)
        limits.maxFileSize = 2
        limits.symbolicLinks = .supported
        fixture.engine.copyTestOptions.destinationLimits = limits
        let undo = UndoRecorder()
        do {
            try await fixture.engine.run(
                FileOperation(.copy(sources, into: destination)), control: OperationControl(), undo: undo,
                resolveConflict: { _ in (.stop, false) })
            Issue.record("Preflight should refuse the batch")
        } catch let OperationError.incompatibleDestination(report) {
            #expect(report.totalCount == 22)
            #expect(report.entries.count == 20)
            #expect(report.omittedCount == 2)
            #expect(report.description.contains("2 more incompatibilities not shown"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(sources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(undo.recorded.isEmpty)
        try fixture.checkBudget()
    }
}
