import AppKit
import Foundation
import Synchronization
import Testing

@testable import Scope
@testable import ScopeEngine

@MainActor struct BrowserTagRefreshTests {
    @Test(arguments: [false, true])
    func iconAndGalleryMetadataEventsUpdateBadgesWithoutChangingSelection(gallery: Bool) async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let state = Mutex(["Red"])
        let cache = FileTagCache { _ in state.withLock { $0 } }
        let model = BrowserModel(engine: FileEngine(pathGuard: .readOnly), location: .folder(folder))
        let controller: any FileBrowsingView =
            gallery
            ? GalleryViewController(model: model, tagCache: cache)
            : IconGridViewController(model: model, style: .grid, tagCache: cache)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var closed = false
        defer {
            if !closed { controller.close() }
            model.close()
            window.close()
        }
        window.contentView = controller.view
        model.onChange = { [weak controller] in controller?.modelDidChange($0) }
        try await waitUntil { model.state == .loaded }
        controller.modelDidChange(.items)
        controller.view.layoutSubtreeIfNeeded()
        let selected = try #require(model.items.first)
        #expect(controller.select([selected.url], scroll: true))
        let collection = try #require(descendant(NSCollectionView.self, in: controller.view))
        collection.layoutSubtreeIfNeeded()
        collection.displayIfNeeded()
        try await waitUntil { cache.cachedTags(for: selected.url) == ["Red"] }
        let item = try #require(collection.item(at: IndexPath(item: 0, section: 0)) as? IconItem)
        let dots = try #require(descendant(TagDotsView.self, in: item.view))
        #expect(dots.accessibilityLabel() == "Tags: Red")
        state.withLock { $0 = ["Blue"] }
        controller.modelDidChange(.metadata)
        try await waitUntil { dots.accessibilityLabel() == "Tags: Blue" }
        #expect(controller.selectedItems.map(\.url) == [selected.url])
        state.withLock { $0 = [] }
        controller.modelDidChange(.metadata)
        try await waitUntil { dots.isHidden }
        #expect(controller.selectedItems.map(\.url) == [selected.url])
        controller.close()
        closed = true
        #expect(cache.cachedTags(for: selected.url) == nil)
    }

    @Test func columnTagsRefreshWithoutClosingDeeperColumnsOrChangingSelection() async throws {
        let root = TestPaths.packages
        let model = BrowserModel(engine: FileEngine(pathGuard: .readOnly), location: .folder(root))
        let state = Mutex(["Red"])
        let cache = FileTagCache { _ in state.withLock { $0 } }
        let controller = ColumnViewController(model: model, tagCache: cache)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            controller.close()
            model.close()
            window.close()
        }
        window.contentView = controller.view
        model.onChange = { [weak controller] in controller?.modelDidChange($0) }
        let folder = root.appendingPathComponent("ScopeEngine")
        let leaf = folder.appendingPathComponent("Package.swift")
        try await waitUntil { model.state == .loaded && controller.select([folder], scroll: false) }
        try await waitUntil { controller.select([leaf], scroll: false) }
        let browser = try #require(controller.view as? NSBrowser)
        browser.display()
        try await waitUntil { cache.cachedTags(for: leaf) == ["Red"] }
        try await waitUntil { !cache.isLoading }
        let lastColumn = browser.lastColumn
        state.withLock { $0 = ["Green", "Blue"] }
        controller.modelDidChange(.metadata)
        browser.displayIfNeeded()
        try await waitUntil { cache.cachedTags(for: leaf) == ["Green", "Blue"] }
        #expect(controller.selectedItems.map(\.url.path) == [leaf.path])
        #expect(browser.lastColumn == lastColumn)
        browser.displayIfNeeded()
        let bitmap = try #require(browser.bitmapImageRepForCachingDisplay(in: browser.bounds))
        browser.cacheDisplay(in: browser.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "column-tags.png")
    }

    @Test func columnsOnlyReadTagsForDisplayedRows() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scope/Browser")
        let reads = Mutex<Set<URL>>([])
        let cache = FileTagCache { url in
            reads.withLock { $0.insert(url) }
            return ["Red"]
        }
        let model = BrowserModel(engine: FileEngine(pathGuard: .readOnly), location: .folder(folder))
        let controller = ColumnViewController(model: model, tagCache: cache)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            controller.close()
            model.close()
            window.close()
        }
        window.contentView = controller.view
        model.onChange = { [weak controller] in controller?.modelDidChange($0) }
        try await waitUntil { model.state == .loaded }
        controller.view.layoutSubtreeIfNeeded()
        controller.view.display()
        try await waitUntil { reads.withLock { !$0.isEmpty } && !cache.isLoading }
        #expect(reads.withLock { !$0.isEmpty })
        #expect(reads.withLock { $0.count } < model.items.count)
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }

    private func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }
}
