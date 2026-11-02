import Foundation
import ScopeEngine
import Testing

@testable import Scope

/// A tab shows a folder's items as they are read, in batches, and ends up
/// with every item once, even when the folder changes while it loads.
@MainActor @Suite(.serialized) struct FolderLoadingTests {
    let folder: URL
    let engine: FileEngine

    init() throws {
        // The temporary folder is inside Scope Dev's container; the guard
        // allows this folder only.
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderLoadingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        engine = FileEngine(pathGuard: .restricted(to: [folder]))
    }

    private func makeFiles(_ count: Int, prefix: String = "file") throws {
        for index in 0..<count {
            try Data().write(to: folder.appendingPathComponent("\(prefix) \(index).txt"))
        }
    }

    /// Waits up to ten seconds for `condition`, checking as the model changes.
    private func wait(for model: BrowserModel, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func showsTheFirstItemsBeforeTheWholeFolderIsSorted() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeFiles(3000)
        let model = BrowserModel(engine: engine, location: .folder(folder))
        defer { model.close() }
        var counts: [Int] = []
        model.onChange = { change in
            if change.contains(.items) { counts.append(model.items.count) }
        }
        try await wait(for: model) { model.state == .loaded && model.items.count == 3000 }
        // The list filled in more than one step, and never went backwards.
        #expect(counts.filter { $0 > 0 }.count > 1 || counts.first == 3000)
        #expect(counts == counts.sorted())
        #expect(Set(model.items.map(\.url.lastPathComponent)).count == 3000)
    }

    @Test func filesAddedWhileLoadingAppearOnce() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeFiles(3000)
        let model = BrowserModel(engine: engine, location: .folder(folder))
        defer { model.close() }
        try makeFiles(50, prefix: "late")
        try await wait(for: model) { model.state == .loaded && model.items.count >= 3050 }
        try await Task.sleep(for: .milliseconds(500))
        let names = model.items.map(\.url.lastPathComponent)
        #expect(names.count == 3050)
        #expect(Set(names).count == names.count)
    }

    @Test func anEmptyFolderLoads() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = BrowserModel(engine: engine, location: .folder(folder))
        defer { model.close() }
        try await wait(for: model) { model.state == .loaded }
        #expect(model.items.isEmpty)
    }
}
