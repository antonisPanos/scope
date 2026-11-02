import AppKit
import Foundation
import Quartz
import Testing

@testable import Scope
@testable import ScopeEngine

@MainActor struct PreviewMetadataTests {
    @Test func metadataEventsRefreshDetailsWithoutRestartingQuickLook() async throws {
        let source = URL(fileURLWithPath: #filePath)
        let model = BrowserModel(
            engine: FileEngine(pathGuard: .readOnly), location: .folder(source.deletingLastPathComponent()))
        defer { model.close() }
        let controller = BrowserViewController(model: model)
        defer { controller.close() }
        _ = controller.view
        model.onChange = { [weak controller] in controller?.update($0) }
        try await waitUntil { model.state == .loaded }
        controller.update([.items, .state])
        #expect(controller.fileView.select([source], scroll: false))
        let grid = try #require(descendant(NSGridView.self, in: controller.view))
        let preview = try #require(descendant(QLPreviewView.self, in: controller.view))
        let initial = grid.cell(atColumnIndex: 0, rowIndex: 0).contentView
        try await waitUntil {
            preview.previewItem != nil && grid.cell(atColumnIndex: 0, rowIndex: 0).contentView !== initial
        }
        let details = grid.cell(atColumnIndex: 0, rowIndex: 0).contentView
        let previewItem = preview.previewItem as AnyObject?
        // The selected FileItem is unchanged; this event represents tags or
        // another metadata-only change. App tests never change source files.
        controller.update(.metadata)
        try await waitUntil { grid.cell(atColumnIndex: 0, rowIndex: 0).contentView !== details }
        #expect(preview.previewItem as AnyObject? === previewItem)
    }

    @Test func metadataWhileTheInitialLoadIsPendingStillLoadsThePreview() async throws {
        let engine = FileEngine(pathGuard: .readOnly)
        let item = try await engine.item(at: URL(fileURLWithPath: #filePath))
        let controller = PreviewPaneController(engine: engine)
        defer { controller.close() }
        _ = controller.view
        controller.show(item, count: 1)
        controller.show(item, count: 1, refreshMetadata: true)
        let preview = try #require(descendant(QLPreviewView.self, in: controller.view))
        try await waitUntil { preview.previewItem != nil }
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
