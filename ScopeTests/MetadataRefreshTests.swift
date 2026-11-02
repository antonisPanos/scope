import Foundation
import Testing

@testable import Scope
@testable import ScopeEngine

@MainActor struct MetadataRefreshTests {
    @Test func metadataNotificationsDoNotDependOnFileItemEquality() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        // A distinct source-only folder avoids sharing a cached listing
        // with other tests that intentionally have no announcement feed.
        let folder = root.appendingPathComponent(".github/workflows")
        let source = folder.appendingPathComponent("ci.yml")
        let announcements = OperationAnnouncements()
        let model = BrowserModel(
            engine: FileEngine(pathGuard: .readOnly), location: .folder(folder),
            announcements: announcements)
        defer { model.close() }
        var notified = false
        model.onChange = { if $0.contains(.metadata) { notified = true } }
        for _ in 0..<500 {
            if model.state == .loaded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.state == .loaded)
        let before = model.items
        // Simulate a metadata-only watcher event without changing a file.
        await Task.detached {
            announcements.announce(FolderItemsChanged(folder: folder, added: [source.lastPathComponent]))
        }.value
        for _ in 0..<500 {
            if notified { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(notified)
        #expect(model.items == before)
    }

    @Test func metadataChangesInvalidateCachedTags() async throws {
        let engine = FileEngine(pathGuard: .readOnly)
        let source = URL(fileURLWithPath: #filePath)
        let missing = source.deletingLastPathComponent().appendingPathComponent("missing-" + UUID().uuidString)
        let model = BrowserModel(engine: engine, location: .folder(missing))
        defer { model.close() }
        let controller = FileListViewController(model: model)
        _ = controller.view
        let item = try await engine.item(at: source)
        for _ in 0..<500 {
            if controller.tags(for: item) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.tags(for: item) != nil)
        controller.modelDidChange(.metadata)
        #expect(controller.tags(for: item) == nil)
    }
}
