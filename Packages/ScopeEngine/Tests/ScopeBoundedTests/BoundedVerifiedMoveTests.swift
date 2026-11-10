import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCOPE_BOUNDED_ROOT"] != nil))
struct BoundedVerifiedMoveTests {
    @Test(arguments: [FileEngine.CopyBoundary.afterVerification, .beforeSourceRetirement], [false, true])
    func changedSourceKeepsPublishedCopyAndUndo(boundary: FileEngine.CopyBoundary, replacement: Bool) async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("source", count: 16)
        let original = Data(repeating: 0x61, count: 16)
        let changed = Data("changed source".utf8)
        let saved = fixture.root.appendingPathComponent("previous-source")
        let destination = fixture.root.appendingPathComponent("destination")
        let copied = destination.appendingPathComponent("source")
        let errors = Mutex<[String]>([])
        fixture.engine.copyTestOptions.boundary = { point, _, _ in
            guard point == boundary else { return }
            do {
                if replacement {
                    try FileManager.default.moveItem(at: source, to: saved)
                    try changed.write(to: source)
                } else {
                    let file = try FileHandle(forWritingTo: source)
                    defer { try? file.close() }
                    try file.truncate(atOffset: 0)
                    try file.write(contentsOf: changed)
                }
            } catch { errors.withLock { $0.append(error.localizedDescription) } }
        }
        let center = OperationCenter(engine: fixture.engine, resolveConflict: { _ in (.stop, false) })
        let announcements = Mutex<[FolderItemsChanged]>([])
        let observer = center.announcements.observe { change in announcements.withLock { $0.append(change) } }
        defer { center.announcements.stop(observer) }
        let id = try await center.enqueue(FileOperation(.move([source], into: destination)))
        await center.waitUntilIdle()
        let snapshots = await center.snapshots()
        let snapshot = try #require(snapshots.first { $0.id == id })
        #expect(snapshot.state == .failed(OperationError.copiedSourceChanged(source.path).localizedDescription))
        #expect(snapshot.canUndo)
        #expect(errors.withLock { $0 }.isEmpty)
        #expect(try Data(contentsOf: source) == changed)
        #expect(try Data(contentsOf: copied) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
        let changes = announcements.withLock { $0 }
        #expect(changes.count == 1)
        #expect(changes.first?.added == ["source"])
        #expect(changes.first?.removed.isEmpty == true)

        let undoID = try #require(try await center.undo(id))
        await center.waitUntilIdle()
        let undoSnapshots = await center.snapshots()
        #expect(undoSnapshots.first { $0.id == undoID }?.state == .done)
        #expect(!FileManager.default.fileExists(atPath: copied.path))
        #expect(try Data(contentsOf: source) == changed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).count == 1)
        try fixture.checkBudget()
    }

    @Test func unchangedSourceCompletesSimulatedMove() async throws {
        let fixture = try BoundedFixture()
        let source = try fixture.write("source", count: 16)
        let destination = fixture.root.appendingPathComponent("destination")
        let center = OperationCenter(engine: fixture.engine, resolveConflict: { _ in (.stop, false) })
        let announcements = Mutex<[FolderItemsChanged]>([])
        let observer = center.announcements.observe { change in announcements.withLock { $0.append(change) } }
        defer { center.announcements.stop(observer) }
        let id = try await center.enqueue(FileOperation(.move([source], into: destination)))
        await center.waitUntilIdle()
        let snapshots = await center.snapshots()
        let snapshot = try #require(snapshots.first { $0.id == id })
        #expect(snapshot.state == .done)
        #expect(snapshot.canUndo)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: destination.appendingPathComponent("source")) == Data(repeating: 0x61, count: 16))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).count == 1)
        let changes = announcements.withLock { $0 }
        #expect(changes.count == 2)
        #expect(changes.contains { $0.added == ["source"] && $0.removed.isEmpty })
        #expect(changes.contains { $0.removed == ["source"] && $0.added.isEmpty })
        try fixture.checkBudget()
    }

    @Test func earlierChildEditedDuringLaterVerificationIsKept() async throws {
        let fixture = try BoundedFixture()
        let source = fixture.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let first = source.appendingPathComponent("a")
        let second = source.appendingPathComponent("b")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let errors = Mutex<[String]>([])
        fixture.engine.verifiedItemHook = { path in
            guard path == second.path else { return }
            do { try Data("changed first".utf8).write(to: first) } catch {
                errors.withLock { $0.append(error.localizedDescription) }
            }
        }
        let destination = fixture.root.appendingPathComponent("destination")
        let center = OperationCenter(engine: fixture.engine, resolveConflict: { _ in (.stop, false) })
        let id = try await center.enqueue(FileOperation(.move([source], into: destination)))
        await center.waitUntilIdle()
        let snapshots = await center.snapshots()
        let snapshot = try #require(snapshots.first { $0.id == id })
        #expect(snapshot.state == .failed(OperationError.copiedSourceChanged(source.path).localizedDescription))
        #expect(snapshot.canUndo)
        #expect(errors.withLock { $0 }.isEmpty)
        #expect(try Data(contentsOf: first) == Data("changed first".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("source/a")) == Data("first".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
        try fixture.checkBudget()
    }
}
