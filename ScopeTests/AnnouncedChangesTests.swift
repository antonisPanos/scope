import Foundation
import ScopeEngine
import Testing

@testable import Scope

/// A tab shows what an operation makes as the operation makes it, and the
/// window that started it selects the result.
@MainActor @Suite(.serialized) struct AnnouncedChangesTests {
    let folder: URL
    let center: OperationCenter
    let model: BrowserModel

    init() throws {
        // Inside Scope Dev's container; the guard allows this folder only.
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnouncedChangesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = FileEngine(pathGuard: .restricted(to: [folder]))
        center = OperationCenter(engine: engine) { _ in (.keepBoth, false) }
        model = BrowserModel(engine: engine, location: .folder(folder), announcements: center.announcements)
    }

    private func cleanUp() {
        model.close()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Waits up to ten seconds for `condition`.
    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private var names: [String] { model.items.map(\.name) }

    @Test func selectsWhatTheOperationAdds() async throws {
        defer { cleanUp() }
        try await wait { model.state == .loaded }
        let id = try await center.enqueue(FileOperation(.newFolder(in: folder, name: "made")))
        model.selectItems(addedBy: id)
        try await wait { names.contains("made") && !model.pendingSelection.isEmpty }
        #expect(model.pendingSelection.map(\.lastPathComponent) == ["made"])
    }

    @Test func selectsItEvenWhenTheNewsCameFirst() async throws {
        defer { cleanUp() }
        try await wait { model.state == .loaded }
        let id = try await center.enqueue(FileOperation(.newFolder(in: folder, name: "early")))
        await center.waitUntilIdle()
        try await wait { names.contains("early") }
        #expect(model.pendingSelection.isEmpty)
        model.selectItems(addedBy: id)
        #expect(model.pendingSelection.map(\.lastPathComponent) == ["early"])
    }

    @Test func selectsEveryItemACopyAdds() async throws {
        defer { cleanUp() }
        let source = folder.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let files = try (1...3).map { index in
            let file = source.appendingPathComponent("file \(index).txt")
            try Data("\(index)".utf8).write(to: file)
            return file
        }
        try await wait { model.state == .loaded && names == ["source"] }
        let id = try await center.enqueue(FileOperation(.copy(files, into: folder)))
        model.selectItems(addedBy: id)
        try await wait { model.pendingSelection.count == 3 }
        #expect(Set(model.pendingSelection.map(\.lastPathComponent)) == ["file 1.txt", "file 2.txt", "file 3.txt"])
        #expect(Set(names).isSuperset(of: ["file 1.txt", "file 2.txt", "file 3.txt"]))
    }

    @Test func otherFoldersChangesAreLeftToTheirTabs() async throws {
        defer { cleanUp() }
        let inner = folder.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try await wait { model.state == .loaded && names == ["inner"] }
        let id = try await center.enqueue(FileOperation(.newFolder(in: inner, name: "deeper")))
        model.selectItems(addedBy: id)
        await center.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(300))
        #expect(names == ["inner"])
        #expect(model.pendingSelection.isEmpty)
    }

    @Test func whichOperationsSelectTheirResult() {
        let file = URL(fileURLWithPath: "/Volumes/ScopeTest/a.txt")
        let folder = URL(fileURLWithPath: "/Volumes/ScopeTest/b")
        #expect(BrowserWindowController.selectsResult(.copy([file], into: folder)))
        #expect(BrowserWindowController.selectsResult(.move([file], into: folder)))
        #expect(BrowserWindowController.selectsResult(.duplicate([file])))
        #expect(BrowserWindowController.selectsResult(.rename(file, to: "c.txt")))
        #expect(BrowserWindowController.selectsResult(.newFolder(in: folder, name: "new")))
        #expect(BrowserWindowController.selectsResult(.extract(file)))
        #expect(!BrowserWindowController.selectsResult(.trash([file])))
        #expect(!BrowserWindowController.selectsResult(.undo(UndoRecord(title: "x"))))
        #expect(!BrowserWindowController.selectsResult(.ejectVolume(folder)))
    }
}
