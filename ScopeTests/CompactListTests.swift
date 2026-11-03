import AppKit
import CoreGraphics
import Synchronization
import Testing

@testable import Scope
@testable import ScopeEngine

@MainActor
struct CompactListTests {
    private let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Scope/Browser")

    @Test func listUsesColumnsAndHasItsOwnIcon() throws {
        let model = BrowserModel(engine: FileEngine(pathGuard: .readOnly), location: .folder(folder))
        let list = BrowserViewController.makeView(for: .list, model: model)
        let details = BrowserViewController.makeView(for: .details, model: model)
        defer {
            list.close()
            details.close()
            model.close()
        }
        #expect((list as? IconGridViewController)?.style == .list)
        #expect(details is FileListViewController)
        #expect(ViewMode.list.symbolName != ViewMode.columns.symbolName)
        #expect(NSImage(systemSymbolName: ViewMode.list.symbolName, accessibilityDescription: "List") != nil)
    }

    @Test(arguments: [false, true])
    func listFillsDownThenAcrossAndReflowsWithTheWindow(legacyScrollers: Bool) async throws {
        let fixture = try ListFixture(folder: folder, size: NSSize(width: 520, height: 220))
        defer { fixture.close() }
        fixture.scroll.scrollerStyle = legacyScrollers ? .legacy : .overlay
        try await fixture.load()
        let frames = try fixture.frames()
        try #require(frames.count > 20)
        #expect(frames[0].minX == frames[1].minX)
        #expect(frames[0].minY < frames[1].minY)
        let nextColumn = try #require(frames.firstIndex { $0.minX > frames[0].minX })
        #expect(nextColumn > 1)
        #expect(frames[nextColumn].minY == frames[0].minY)
        #expect(!fixture.scroll.hasVerticalScroller)
        #expect(fixture.scroll.hasHorizontalScroller)
        #expect(fixture.collection.frame.height <= fixture.scroll.contentSize.height + 1)
        let last = try #require(fixture.model.items.last)
        #expect(fixture.controller.select([last.url], scroll: true))
        fixture.collection.layoutSubtreeIfNeeded()
        #expect(fixture.scroll.contentView.bounds.minX > 0)
        #expect(fixture.scroll.contentView.bounds.minY == 0)
        fixture.window.setContentSize(NSSize(width: 520, height: 360))
        fixture.controller.view.layoutSubtreeIfNeeded()
        let taller = try fixture.frames()
        let tallerNextColumn = try #require(taller.firstIndex { $0.minX > taller[0].minX })
        #expect(tallerNextColumn > nextColumn)
        #expect(fixture.collection.frame.height <= fixture.scroll.contentSize.height + 1)
        #expect(fixture.controller.selectedItems.map(\.url) == [last.url])
    }

    @Test func listKeepsMultipleSelectionAndRefreshesTags() async throws {
        let tags = Mutex(["Red"])
        let cache = FileTagCache { _ in tags.withLock { $0 } }
        let fixture = try ListFixture(folder: folder, size: NSSize(width: 520, height: 220), cache: cache)
        defer { fixture.close() }
        try await fixture.load()
        let selected = Array(fixture.model.items.prefix(2))
        #expect(fixture.controller.select(selected.map(\.url), scroll: true))
        try await waitUntil { cache.cachedTags(for: selected[0].url) == ["Red"] }
        let item = try #require(fixture.collection.item(at: IndexPath(item: 0, section: 0)) as? CompactListItem)
        let dots = try #require(descendant(TagDotsView.self, in: item.view))
        #expect(dots.accessibilityLabel() == "Tags: Red")
        tags.withLock { $0 = ["Blue", "Green"] }
        fixture.controller.modelDidChange(.metadata)
        try await waitUntil { dots.accessibilityLabel() == "Tags: Blue, Green" }
        #expect(fixture.controller.selectedItems.map(\.url) == selected.map(\.url))
        tags.withLock { $0 = [] }
        fixture.controller.modelDidChange(.metadata)
        try await waitUntil { dots.isHidden }
        #expect(fixture.controller.selectedItems.map(\.url) == selected.map(\.url))
    }

    @Test func arrowKeysFollowTheColumnLayout() async throws {
        let fixture = try ListFixture(folder: folder, size: NSSize(width: 520, height: 220))
        defer { fixture.close() }
        try await fixture.load()
        let frames = try fixture.frames()
        let nextColumn = try #require(frames.firstIndex { $0.minX > frames[0].minX })
        #expect(fixture.window.makeFirstResponder(fixture.collection))
        fixture.controller.select([fixture.model.items[0].url], scroll: true)
        fixture.collection.keyDown(with: try key(.downArrow, code: 125))
        #expect(fixture.controller.selectedItems.map(\.url) == [fixture.model.items[1].url])
        fixture.collection.keyDown(with: try key(.rightArrow, code: 124))
        #expect(fixture.controller.selectedItems.map(\.url) == [fixture.model.items[nextColumn + 1].url])
        fixture.collection.keyDown(with: try key(.leftArrow, code: 123))
        #expect(fixture.controller.selectedItems.map(\.url) == [fixture.model.items[1].url])
    }

    @Test(arguments: [false, true])
    func mouseWheelScrollsAcrossColumns(horizontal: Bool) async throws {
        let fixture = try ListFixture(folder: folder, size: NSSize(width: 520, height: 220))
        defer { fixture.close() }
        try await fixture.load()
        let wheel = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                wheel1: horizontal ? 0 : -3, wheel2: horizontal ? -3 : 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: wheel))
        fixture.scroll.scrollWheel(with: event)
        #expect(fixture.scroll.contentView.bounds.minX > 0)
        #expect(fixture.scroll.contentView.bounds.minY == 0)
    }

    @Test func navigationStartsAtTheFirstColumn() async throws {
        let fixture = try ListFixture(folder: folder, size: NSSize(width: 520, height: 220))
        defer { fixture.close() }
        try await fixture.load()
        fixture.controller.select([try #require(fixture.model.items.last).url], scroll: true)
        #expect(fixture.scroll.contentView.bounds.minX > 0)
        fixture.model.navigate(to: .folder(folder.deletingLastPathComponent()))
        #expect(fixture.scroll.contentView.bounds.origin == .zero)
    }

    @Test(arguments: [NSAppearance.Name.aqua.rawValue, NSAppearance.Name.darkAqua.rawValue])
    func rendersCompactColumnsAndTheNewIcon(appearance: String) async throws {
        let cache = FileTagCache { url in url.lastPathComponent.count.isMultiple(of: 3) ? ["Red", "Blue"] : [] }
        let fixture = try ListFixture(folder: folder, size: NSSize(width: 760, height: 260), cache: cache)
        defer { fixture.close() }
        fixture.window.appearance = try #require(NSAppearance(named: NSAppearance.Name(appearance)))
        try await fixture.load()
        fixture.controller.select([try #require(fixture.model.items.first).url], scroll: false)
        try await waitUntil { !cache.isLoading }
        fixture.controller.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(
            fixture.controller.view.bitmapImageRepForCachingDisplay(in: fixture.controller.view.bounds))
        fixture.controller.view.cacheDisplay(in: fixture.controller.view.bounds, to: bitmap)
        Attachment.record(
            try #require(bitmap.representation(using: .png, properties: [:])), named: "compact-list-\(appearance).png")
        let icon = try #require(NSImage(systemSymbolName: ViewMode.list.symbolName, accessibilityDescription: "List"))
        let iconBackground = BackgroundView(color: Palette.windowBackground)
        fixture.window.contentView = iconBackground
        fixture.window.setContentSize(NSSize(width: 64, height: 42))
        let iconView = NSImageView(image: icon)
        iconView.frame = NSRect(x: 8, y: 8, width: 48, height: 26)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = Palette.primaryText
        iconBackground.addSubview(iconView)
        iconBackground.layoutSubtreeIfNeeded()
        iconBackground.displayIfNeeded()
        let iconBitmap = try #require(iconBackground.bitmapImageRepForCachingDisplay(in: iconBackground.bounds))
        iconBackground.cacheDisplay(in: iconBackground.bounds, to: iconBitmap)
        Attachment.record(
            try #require(iconBitmap.representation(using: .png, properties: [:])), named: "list-icon-\(appearance).png")
    }

    @Test func narrowPanesAndLongNamesKeepTagsVisible() async throws {
        let fixture = try ListFixture(folder: folder, size: NSSize(width: 190, height: 180))
        defer { fixture.close() }
        try await fixture.load()
        let first = try #require(fixture.frames().first)
        #expect(first.maxX <= fixture.scroll.contentSize.width)
        let file = try #require(fixture.model.items.first)
        let item = CompactListItem()
        _ = item.view
        item.view.frame = NSRect(origin: .zero, size: first.size)
        item.show(file, tags: ColorTags.names)
        let name = try #require(item.textField)
        name.stringValue = String(repeating: "A long filename ", count: 20) + ".tar.gz"
        item.view.layoutSubtreeIfNeeded()
        let dots = try #require(descendant(TagDotsView.self, in: item.view))
        #expect(!dots.isHidden)
        #expect(item.view.bounds.contains(dots.convert(dots.bounds, to: item.view)))
        #expect(name.lineBreakMode == .byTruncatingMiddle)
        item.isSelected = true
        #expect(item.view.layer?.backgroundColor != nil)
        item.highlightState = .forDeselection
        #expect(item.view.layer?.backgroundColor == nil)
        item.show(file, tags: [])
        #expect(dots.isHidden)
        #expect(name.stringValue == file.name)
    }

    @Test func openingQuickLookAndTypeSelectionKeepWorking() async throws {
        let fixture = try ListFixture(folder: folder, size: NSSize(width: 520, height: 220))
        defer { fixture.close() }
        try await fixture.load()
        let selected = try #require(fixture.model.items.first)
        fixture.controller.select([selected.url], scroll: false)
        #expect(fixture.window.makeFirstResponder(fixture.collection))
        var opened: [URL] = []
        var quickLook = false
        fixture.controller.onOpen = { opened = $0.map(\.url) }
        fixture.controller.onQuickLook = { quickLook = true }
        fixture.collection.keyDown(with: try key(.downArrow, code: 125, flags: .command))
        #expect(opened == [selected.url])
        fixture.collection.keyDown(with: try characterKey(" ", code: 49))
        #expect(quickLook)
        let last = try #require(fixture.model.items.last)
        fixture.collection.keyDown(with: try characterKey(last.name, code: 0))
        #expect(fixture.controller.selectedItems.map(\.url) == [last.url])
        #expect(fixture.scroll.contentView.bounds.minX > 0)
        fixture.controller.modelDidChange(.items)
        #expect(fixture.controller.selectedItems.map(\.url) == [last.url])
    }

    private func key(_ special: NSEvent.SpecialKey, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let text = String(try #require(UnicodeScalar(special.rawValue)))
        return try characterKey(text, code: code, flags: flags)
    }

    private func characterKey(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        return try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }
}

@MainActor
private final class ListFixture {
    let model: BrowserModel
    let controller: IconGridViewController
    let window: NSWindow
    let scroll: NSScrollView
    let collection: NSCollectionView

    init(folder: URL, size: NSSize, cache: FileTagCache? = nil) throws {
        let model = BrowserModel(engine: FileEngine(pathGuard: .readOnly), location: .folder(folder))
        let controller = IconGridViewController(model: model, style: .list, tagCache: cache)
        self.model = model
        self.controller = controller
        do {
            scroll = try #require(controller.view as? NSScrollView)
            collection = try #require(scroll.documentView as? NSCollectionView)
        } catch {
            controller.close()
            model.close()
            throw error
        }
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        model.onChange = { [weak controller] in controller?.modelDidChange($0) }
    }

    func load() async throws {
        try await waitUntil { self.model.state == .loaded }
        controller.modelDidChange(.items)
        controller.view.layoutSubtreeIfNeeded()
        collection.layoutSubtreeIfNeeded()
        collection.displayIfNeeded()
    }

    func frames() throws -> [NSRect] {
        let layout = try #require(collection.collectionViewLayout)
        return try model.items.indices.map { index in
            try #require(layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))).frame
        }
    }

    func close() {
        controller.close()
        model.close()
        window.close()
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition(), sourceLocation: sourceLocation)
}

@MainActor
private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
}
