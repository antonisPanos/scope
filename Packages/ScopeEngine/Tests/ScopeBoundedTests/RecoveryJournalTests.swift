import Darwin
import Foundation
import Testing

@testable import ScopeEngine

@Suite struct RecoveryJournalTests {
    private func store(_ fixture: BoundedFixture) throws -> URL {
        let url = fixture.root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private func identity(_ url: URL) throws -> RecoveryJournal.Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        return RecoveryJournal.Identity(info)
    }

    @Test func activeSessionAndCrashStatesAreConservative() throws {
        let fixture = try BoundedFixture()
        let root = try store(fixture)
        let guarder = PathGuard.restricted(to: [fixture.root])
        let folder = fixture.root.appendingPathComponent("destination")
        let target = folder.appendingPathComponent("copy")
        let source = try fixture.write("source", count: 4)
        let stageName = FileEngine.partialPrefix + UUID().uuidString
        let stage = folder.appendingPathComponent(stageName)
        try Data([1, 2]).write(to: stage)
        var owner: RecoveryJournal? = try RecoveryJournal(root: root, pathGuard: guarder)
        let observer = try RecoveryJournal(root: root, pathGuard: guarder)
        let intent = try #require(owner).createIntent(
            source: source, destination: target, stagingName: stageName, action: .copy)
        #expect(try observer.discover(in: folder).first?.ownership == .active)
        #expect(throws: RecoveryJournal.Failure.self) { try observer.forget(intent.id) }
        _ = try #require(owner).transition(intent.id, to: .staging, identity: identity(stage))
        owner = nil
        #expect(try observer.discover(in: folder).first?.ownership == .candidate)
        try FileManager.default.removeItem(at: stage)
        #expect(try observer.discover(in: folder).first?.ownership == .ambiguous)
        try observer.forget(intent.id)
        #expect(try observer.discover(in: folder).isEmpty)
    }

    @Test func publishingAndInvalidTransitions() throws {
        let fixture = try BoundedFixture()
        let root = try store(fixture)
        let guarder = PathGuard.restricted(to: [fixture.root])
        let folder = fixture.root.appendingPathComponent("destination")
        let source = try fixture.write("source", count: 1)
        let stageName = FileEngine.partialPrefix + UUID().uuidString
        let stage = folder.appendingPathComponent(stageName)
        try Data([3]).write(to: stage)
        var owner: RecoveryJournal? = try RecoveryJournal(root: root, pathGuard: guarder)
        let record = try #require(owner).createIntent(
            source: source, destination: folder.appendingPathComponent("out"), stagingName: stageName, action: .copy)
        #expect(throws: RecoveryJournal.Failure.self) { try #require(owner).transition(record.id, to: .published) }
        let id = try identity(stage)
        _ = try #require(owner).transition(record.id, to: .staging, identity: id)
        _ = try #require(owner).transition(record.id, to: .publishing)
        _ = try #require(owner).transition(record.id, to: .published, identity: id)
        owner = nil
        let observer = try RecoveryJournal(root: root, pathGuard: guarder)
        #expect(try observer.discover(in: folder).first?.ownership == .published)
        #expect(FileManager.default.fileExists(atPath: stage.path))
    }

    @Test func malformedAndOversizedRecordsFailClosed() throws {
        let fixture = try BoundedFixture()
        let root = try store(fixture)
        let journal = try RecoveryJournal(root: root, pathGuard: .restricted(to: [fixture.root]))
        let name = "record-" + UUID().uuidString
        let url = root.appendingPathComponent(name)
        try Data("{\"version\":999}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(throws: RecoveryJournal.Failure.self) {
            try journal.discover(in: fixture.root.appendingPathComponent("destination"))
        }
        try Data(repeating: 0, count: RecoveryJournal.maxRecordBytes + 1).write(to: url)
        #expect(throws: RecoveryJournal.Failure.self) {
            try journal.discover(in: fixture.root.appendingPathComponent("destination"))
        }
    }
}

extension RecoveryJournalTests {
    @Test func intentAndReplacedLockRemainAmbiguous() throws {
        let fixture = try BoundedFixture()
        let root = try store(fixture)
        let guarder = PathGuard.restricted(to: [fixture.root])
        let folder = fixture.root.appendingPathComponent("destination")
        let source = try fixture.write("source", count: 1)
        var owner: RecoveryJournal? = try RecoveryJournal(root: root, pathGuard: guarder)
        let record = try #require(owner).createIntent(
            source: source, destination: folder.appendingPathComponent("out"),
            stagingName: FileEngine.partialPrefix + UUID().uuidString, action: .copy)
        owner = nil
        let observer = try RecoveryJournal(root: root, pathGuard: guarder)
        #expect(try observer.discover(in: folder).first?.ownership == .ambiguous)
        let lock = root.appendingPathComponent("session-" + record.session.uuidString)
        let oldLock = open(lock.path, O_RDONLY | O_CLOEXEC)
        #expect(oldLock >= 0)
        defer { if oldLock >= 0 { close(oldLock) } }
        try FileManager.default.removeItem(at: lock)
        try Data().write(to: lock)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
        #expect(try observer.discover(in: folder).first?.ownership == .ambiguous)
        #expect(throws: Error.self) { try observer.forget(record.id) }
    }

    @Test func rejectsOversizedPathsAndInvalidStagingNames() throws {
        let fixture = try BoundedFixture()
        let root = try store(fixture)
        let journal = try RecoveryJournal(root: root, pathGuard: .restricted(to: [fixture.root]))
        let source = try fixture.write("source", count: 1)
        let target = fixture.root.appendingPathComponent("destination/out")
        #expect(throws: RecoveryJournal.Failure.self) {
            try journal.createIntent(
                source: source, destination: target, stagingName: ".scope-partial-lookalike", action: .copy)
        }
        let longSource = fixture.root.appendingPathComponent(
            String(repeating: "a", count: RecoveryJournal.maxPathBytes + 1))
        #expect(throws: Error.self) {
            try journal.createIntent(
                source: longSource, destination: target,
                stagingName: FileEngine.partialPrefix + UUID().uuidString, action: .copy)
        }
    }
}

extension RecoveryJournalTests {
    @Test func resolvedCyclesDoNotExhaustRecordBudget() throws {
        let fixture = try BoundedFixture()
        let root = try store(fixture)
        let journal = try RecoveryJournal(root: root, pathGuard: .restricted(to: [fixture.root]), recordLimit: 2)
        let source = try fixture.write("source", count: 1)
        let target = fixture.root.appendingPathComponent("destination/out")
        for _ in 0..<5 {
            let record = try journal.createIntent(
                source: source, destination: target,
                stagingName: FileEngine.partialPrefix + UUID().uuidString, action: .copy)
            _ = try journal.transition(record.id, to: .resolved)
        }
        #expect(try journal.discover(in: target.deletingLastPathComponent()).isEmpty)
    }

    @Test func maintenanceKeepsActiveSessionsAndReclaimsStaleResolved() throws {
        let fixture = try BoundedFixture()
        let root = try store(fixture)
        let guarder = PathGuard.restricted(to: [fixture.root])
        let source = try fixture.write("source", count: 1)
        let folder = fixture.root.appendingPathComponent("destination")
        var owner: RecoveryJournal? = try RecoveryJournal(root: root, pathGuard: guarder)
        let record = try #require(owner).createIntent(
            source: source, destination: folder.appendingPathComponent("out"),
            stagingName: FileEngine.partialPrefix + UUID().uuidString, action: .copy)
        let observer = try RecoveryJournal(root: root, pathGuard: guarder)
        try observer.maintain()
        #expect(try observer.discover(in: folder).first?.ownership == .active)
        let recordURL = root.appendingPathComponent("record-" + record.id.uuidString)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        object["phase"] = "resolved"
        let bytes = try JSONSerialization.data(withJSONObject: object)
        try bytes.write(to: recordURL)
        owner = nil
        try observer.maintain()
        #expect(try observer.discover(in: folder).isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("session-" + record.session.uuidString).path))
    }
}

extension RecoveryJournalTests {
    @Test func identityRefreshRejectsDifferentObject() throws {
        let fixture = try BoundedFixture()
        let root = try store(fixture)
        let journal = try RecoveryJournal(root: root, pathGuard: .restricted(to: [fixture.root]))
        let source = try fixture.write("source", count: 1)
        let other = try fixture.write("other", count: 1)
        let folder = fixture.root.appendingPathComponent("destination")
        let stageName = FileEngine.partialPrefix + UUID().uuidString
        let stage = folder.appendingPathComponent(stageName)
        try Data([1]).write(to: stage)
        let record = try journal.createIntent(
            source: source, destination: folder.appendingPathComponent("out"), stagingName: stageName, action: .copy)
        _ = try journal.transition(record.id, to: .staging, identity: identity(stage))
        #expect(throws: RecoveryJournal.Failure.self) {
            try journal.transition(record.id, to: .publishing, identity: identity(other))
        }
        var modifiedBirth = stat()
        #expect(lstat(stage.path, &modifiedBirth) == 0)
        modifiedBirth.st_birthtimespec.tv_sec -= 1
        let refreshed = RecoveryJournal.Identity(modifiedBirth)
        let updated = try journal.transition(record.id, to: .publishing, identity: refreshed)
        #expect(updated.staging == refreshed)
    }
}
