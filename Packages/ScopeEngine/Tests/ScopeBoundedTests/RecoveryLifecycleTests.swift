import Darwin
import Foundation
import Testing

@testable import ScopeEngine

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCOPE_BOUNDED_ROOT"] != nil))
struct RecoveryLifecycleTests {
    enum Injected: Error { case failure }

    private func session(_ fixture: BoundedFixture, fail: RecoverySession.Point? = nil) throws -> RecoverySession {
        let root = fixture.root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return RecoverySession(root: root, pathGuard: .restricted(to: [fixture.root])) { point in
            if point == fail { throw Injected.failure }
        }
    }

    @Test func successfulCopiesShareSessionAndResolveRecords() async throws {
        let fixture = try BoundedFixture()
        let shared = try session(fixture)
        let source = try fixture.write("source", count: 8)
        let folder = fixture.root.appendingPathComponent("destination")
        var first = fixture.engine
        first.recoverySession = shared
        var second = fixture.engine
        second.recoverySession = shared
        try await first.copyItem(at: source, to: folder.appendingPathComponent("one"))
        try await second.copyItem(at: source, to: folder.appendingPathComponent("two"))
        let journal = try shared.journal()
        #expect(try journal.discover(in: folder).isEmpty)
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: fixture.root.appendingPathComponent("recovery").path)
        #expect(entries.filter { $0.hasPrefix("session-") }.count == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent("one")).count == 8)
        #expect(try Data(contentsOf: folder.appendingPathComponent("two")).count == 8)
    }

    @Test(arguments: [RecoverySession.Point.intent, .staging, .publishing, .published, .resolved])
    func injectedFailureKeepsCorrectBoundary(point: RecoverySession.Point) async throws {
        let fixture = try BoundedFixture()
        let shared = try session(fixture, fail: point)
        let source = try fixture.write("source", count: 8)
        let folder = fixture.root.appendingPathComponent("destination")
        let target = folder.appendingPathComponent("out")
        var configured = fixture.engine
        configured.recoverySession = shared
        let engine = configured
        if point == .published || point == .resolved {
            await #expect(throws: PublishedCopyFinalizationError.self) {
                try await engine.copyItem(at: source, to: target)
            }
            #expect(FileManager.default.fileExists(atPath: target.path))
        } else {
            await #expect(throws: (any Error).self) { try await engine.copyItem(at: source, to: target) }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        let records = try shared.journal().discover(in: folder)
        switch point {
        case .intent:
            #expect(records.isEmpty)
        case .staging:
            #expect(records.first?.record.phase == .intent)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
        case .publishing:
            #expect(records.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        case .published:
            #expect(records.first?.record.phase == .publishing)
        case .resolved:
            #expect(records.first?.record.phase == .published)
        }
    }

    @Test func publicationJournalFailureKeepsMoveSourceAndUndo() async throws {
        let fixture = try BoundedFixture()
        let shared = try session(fixture, fail: .published)
        let source = try fixture.write("source", count: 8)
        let folder = fixture.root.appendingPathComponent("destination")
        fixture.engine.recoverySession = shared
        let engine = fixture.engine
        let undo = UndoRecorder()
        await #expect(throws: (any Error).self) {
            try await engine.run(
                FileOperation(.move([source], into: folder)), control: OperationControl(),
                undo: undo, resolveConflict: { _ in (.stop, false) })
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("source").path))
        #expect(undo.recorded.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    }
}

extension RecoveryLifecycleTests {
    @Test func caughtCopyFailureRemovesConfirmedPartialAndRecord() async throws {
        let fixture = try BoundedFixture()
        let shared = try session(fixture)
        let source = try fixture.write("source", count: 256)
        let folder = fixture.root.appendingPathComponent("destination")
        fixture.engine.recoverySession = shared
        fixture.engine.writeFault = { _, _ in ENOSPC }
        let engine = fixture.engine
        await #expect(throws: (any Error).self) {
            try await engine.copyItem(at: source, to: folder.appendingPathComponent("out"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(try shared.journal().discover(in: folder).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}

extension RecoveryLifecycleTests {
    @Test(arguments: ["file", "clone-attempt", "directory"])
    func publishedRecordUsesPinnedIdentityAfterOldSourceMetadata(kind: String) async throws {
        let fixture = try BoundedFixture()
        let shared = try session(fixture, fail: .resolved)
        let source: URL
        if kind == "directory" {
            source = fixture.root.appendingPathComponent("source-directory")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data([1, 2]).write(to: source.appendingPathComponent("child"))
        } else {
            source = try fixture.write("source", count: 8)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 946_684_800)], ofItemAtPath: source.path)
        let target = fixture.root.appendingPathComponent("destination/out")
        fixture.engine.recoverySession = shared
        fixture.engine.copyTestOptions.disableCloning = kind != "clone-attempt"
        let engine = fixture.engine
        await #expect(throws: PublishedCopyFinalizationError.self) {
            try await engine.copyItem(at: source, to: target)
        }
        let records = try shared.journal().discover(in: target.deletingLastPathComponent())
        let record = try #require(records.first?.record)
        var actual = stat()
        #expect(lstat(target.path, &actual) == 0)
        #expect(record.phase == .published)
        #expect(record.published == RecoveryJournal.Identity(actual))
    }
}
