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

    @Test func expandedFolderUpdatesKeepTheSelectedPreviewAndFocus() async throws {
        let root = TestPaths.packages.deletingLastPathComponent()
        let announcements = OperationAnnouncements()
        let suite = "ScopePreviewSelectionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BrowserModel(
            engine: FileEngine(pathGuard: .readOnly), location: .folder(root),
            announcements: announcements, settings: AppSettings(defaults: defaults))
        let controller = BrowserViewController(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        defer {
            window.contentViewController = nil
            controller.close()
            model.close()
        }
        window.contentViewController = controller
        model.onChange = { [weak controller] in controller?.update($0) }
        try await waitUntil { model.state == .loaded }
        let list = try #require(controller.fileView as? FileListViewController)
        let outline = list.outlineView
        let folder = try #require(list.roots.first { $0.item.name == "docs" })
        outline.expandItem(folder)
        try await waitUntil { folder.children?.contains { $0.item.name == "ARCHITECTURE.md" } == true }
        let file = try #require(folder.children?.first { $0.item.name == "ARCHITECTURE.md" })
        let url = file.item.url
        let preview = try #require(descendant(QLPreviewView.self, in: controller.view))
        preview.superview?.isHidden = false
        let grid = try #require(descendant(NSGridView.self, in: controller.view))
        try #require(window.makeFirstResponder(outline))
        try #require(list.select([url], scroll: false))
        let initial = grid.cell(atColumnIndex: 0, rowIndex: 0).contentView
        try await waitUntil {
            preview.previewItem != nil && grid.cell(atColumnIndex: 0, rowIndex: 0).contentView !== initial
        }
        let previewItem = preview.previewItem as AnyObject?
        let details = grid.cell(atColumnIndex: 0, rowIndex: 0).contentView
        var reportedSelections: [[URL]] = []
        controller.onSelectionChange = { [weak list] in
            if let list { reportedSelections.append(list.selectedItems.map(\.url)) }
        }

        // Drive the expanded folder's watcher path without changing source files.
        let change = FolderItemsChanged(folder: folder.item.url, added: [url.lastPathComponent])
        await Task.detached { announcements.announce(change) }.value
        try await waitUntil {
            grid.numberOfRows > 0 && grid.cell(atColumnIndex: 0, rowIndex: 0).contentView !== details
        }
        #expect(list.selectedItems.map(\.url) == [url])
        #expect(window.firstResponder === outline)
        #expect(preview.previewItem as AnyObject? === previewItem)

        let previousRow = outline.row(forItem: file)
        let listing = try #require(folder.childrenListing)
        listing.update(sort: FileSort(key: .name, ascending: false), showHidden: false)
        try await waitUntil { outline.row(forItem: file) != previousRow }
        #expect(outline.selectedRow == outline.row(forItem: file))
        #expect(list.selectedItems.map(\.url) == [url])
        #expect(window.firstResponder === outline)
        #expect(preview.previewItem as AnyObject? === previewItem)
        #expect(reportedSelections.allSatisfy { $0 == [url] })

        list.select([], scroll: false)
        #expect(preview.previewItem == nil)
        #expect(reportedSelections.last == [])
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
        try #require(condition())
    }
}
