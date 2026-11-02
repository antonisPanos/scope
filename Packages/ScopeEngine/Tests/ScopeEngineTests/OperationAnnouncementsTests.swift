import Foundation
import Testing

@testable import ScopeEngine

/// Operations announce each change to a folder as they make it, so open
/// views can show it without waiting for the folder watcher.
@Suite(.serialized) struct OperationAnnouncementsTests {
    let disk: TestVolume
    let center: OperationCenter
    let heard = Recorded<FolderItemsChanged>()

    init() throws {
        disk = try TestVolume(name: "ScopeAnnounce")
        let engine = FileEngine(pathGuard: .restricted(to: [disk.mountPoint]))
        center = OperationCenter(engine: engine) { _ in (.keepBoth, false) }
        let heard = heard
        center.announcements.observe { heard.append($0) }
    }

    /// What was heard about `folder`, in order.
    private func heard(in folder: URL) -> [FolderItemsChanged] {
        let path = folder.resolvingSymlinksInPath().path
        return heard.all.filter { $0.folder.resolvingSymlinksInPath().path == path }
    }

    private func run(_ kind: FileOperation.Kind) async throws -> UUID {
        let id = try await center.enqueue(FileOperation(kind))
        await center.waitUntilIdle()
        return id
    }

    // MARK: - Which folders a step changed

    @Test func eachUndoStepNamesTheFoldersItChanged() {
        let folder = URL(fileURLWithPath: "/Volumes/T/a")
        let other = URL(fileURLWithPath: "/Volumes/T/b")
        let trash = URL(fileURLWithPath: "/Volumes/T/.Trashes/501/x.txt")

        let identity = FileIdentity(inode: 1, modified: 0, size: 0)
        #expect(
            FolderItemsChanged.changes(for: .trashCreated(folder.appendingPathComponent("new.txt"), fileID: identity))
                == [FolderItemsChanged(folder: folder, added: ["new.txt"])])
        // A rename stays in one folder: one change, both names.
        #expect(
            FolderItemsChanged.changes(
                for: .moveBack(from: folder.appendingPathComponent("new"), to: folder.appendingPathComponent("old"))
            ) == [FolderItemsChanged(folder: folder, added: ["new"], removed: ["old"])])
        // A move leaves one folder for another.
        #expect(
            FolderItemsChanged.changes(
                for: .moveBack(from: other.appendingPathComponent("x"), to: folder.appendingPathComponent("x"))
            ) == [
                FolderItemsChanged(folder: other, added: ["x"]),
                FolderItemsChanged(folder: folder, removed: ["x"]),
            ])
        #expect(
            FolderItemsChanged.changes(for: .putBack(trashed: trash, original: folder.appendingPathComponent("x.txt")))
                == [FolderItemsChanged(folder: folder, removed: ["x.txt"])])
    }

    @Test func reversedSwapsAddedAndRemoved() {
        let change = FolderItemsChanged(folder: URL(fileURLWithPath: "/Volumes/T"), added: ["a"], removed: ["b"])
        #expect(change.reversed == FolderItemsChanged(folder: change.folder, added: ["b"], removed: ["a"]))
        #expect(change.names == ["a", "b"])
    }

    // MARK: - Operations through the center

    @Test func announcesCreatedRenamedAndTrashedItems() async throws {
        try disk.write("a.txt", "a")
        _ = try await run(.newFolder(in: disk.work, name: "made"))
        _ = try await run(.rename(disk.url("a.txt"), to: "b.txt"))
        _ = try await run(.trash([disk.url("b.txt")]))
        let changes = heard(in: disk.work)
        #expect(changes.count == 3)
        #expect(changes.first?.added == ["made"])
        #expect(changes.dropFirst().first.map { [$0.added, $0.removed] } == [["b.txt"], ["a.txt"]])
        #expect(changes.last?.removed == ["b.txt"])
    }

    @Test func namesTheOperationThatMadeTheChange() async throws {
        let first = try await run(.newFolder(in: disk.work, name: "one"))
        let second = try await run(.newFolder(in: disk.work, name: "two"))
        #expect(heard(in: disk.work).map(\.operation) == [first, second])
    }

    @Test func announcesAMoveInBothFolders() async throws {
        try disk.write("a.txt", "a")
        try FileManager.default.createDirectory(at: disk.url("sub"), withIntermediateDirectories: true)
        _ = try await run(.move([disk.url("a.txt")], into: disk.url("sub")))
        #expect(heard(in: disk.url("sub")).map(\.added) == [["a.txt"]])
        #expect(heard(in: disk.work).map(\.removed) == [["a.txt"]])
    }

    @Test func announcesACopyAndItsUndo() async throws {
        try disk.write("a.txt", "a")
        try FileManager.default.createDirectory(at: disk.url("sub"), withIntermediateDirectories: true)
        let copy = try await run(.copy([disk.url("a.txt")], into: disk.url("sub")))
        #expect(heard(in: disk.url("sub")).map(\.added) == [["a.txt"]])

        try #require(try await center.undo(copy) != nil)
        await center.waitUntilIdle()
        #expect(!disk.exists("sub/a.txt"))
        #expect(heard(in: disk.url("sub")).map(\.removed) == [[], ["a.txt"]])
    }

    @Test func announcesPuttingBackFromTheTrash() async throws {
        try disk.write("a.txt", "a")
        let trash = try await run(.trash([disk.url("a.txt")]))
        try #require(try await center.undo(trash) != nil)
        await center.waitUntilIdle()
        #expect(disk.exists("a.txt"))
        #expect(heard(in: disk.work).map(\.added) == [[], ["a.txt"]])
    }

    @Test func stopEndsTheAnnouncements() async throws {
        let quiet = Recorded<FolderItemsChanged>()
        let token = center.announcements.observe { quiet.append($0) }
        _ = try await run(.newFolder(in: disk.work, name: "one"))
        center.announcements.stop(token)
        _ = try await run(.newFolder(in: disk.work, name: "two"))
        #expect(quiet.all.map(\.added) == [["one"]])
        // The other observer still hears both.
        #expect(heard(in: disk.work).map(\.added) == [["one"], ["two"]])
    }

    @Test func announcesDeletingForGoodOnADiskWithNoTrash() async throws {
        var engine = FileEngine(pathGuard: .restricted(to: [disk.mountPoint]))
        engine.trashRefusal = { _ in true }
        let heard = Recorded<FolderItemsChanged>()
        let center = OperationCenter(engine: engine, resolveConflict: { _ in (.keepBoth, false) }) { _ in true }
        center.announcements.observe { heard.append($0) }
        try disk.write("a.txt", "a")
        _ = try await center.enqueue(FileOperation(.trash([disk.url("a.txt")])))
        await center.waitUntilIdle()
        #expect(!disk.exists("a.txt"))
        #expect(heard.all.map(\.removed) == [["a.txt"]])
    }
}
