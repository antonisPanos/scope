import AppKit
import Testing

@testable import Scope
@testable import ScopeEngine

@MainActor struct CutAppearanceTests {
    private var folder: URL { TestPaths.packages.appendingPathComponent("ScopeEngine") }

    @Test(arguments: [false, true])
    func reusedContentRestoresOpacityWithoutFadingSelection(hidden: Bool) async throws {
        let root = TestPaths.packages.deletingLastPathComponent()
        let engine = FileEngine(pathGuard: .readOnly)
        let file = try await engine.item(at: root.appendingPathComponent(hidden ? ".swiftlint.yml" : "README.md"))
        let image = try #require(NSImage(systemSymbolName: "doc", accessibilityDescription: nil))
        let icon = IconItem()
        _ = icon.view
        icon.isSelected = true
        icon.show(file, image: image, iconSize: 64, showsName: true, tags: ["Red"], isCut: true)
        #expect(icon.imageView?.alphaValue == 0.5)
        #expect(icon.textField?.alphaValue == 0.5)
        #expect(icon.view.alphaValue == 1)
        #expect(descendant(TagDotsView.self, in: icon.view)?.superview?.alphaValue == 0.5)
        icon.highlightState = .asDropTarget
        icon.show(file, image: image, iconSize: 64, showsName: true, tags: ["Blue"], isCut: true)
        #expect(icon.imageView?.alphaValue == 0.5)
        icon.show(file, image: image, iconSize: 64, showsName: true)
        #expect(icon.imageView?.alphaValue == (hidden ? 0.55 : 1))
        #expect(icon.textField?.alphaValue == 1)
        #expect(icon.isSelected)

        let list = CompactListItem()
        _ = list.view
        list.isSelected = true
        list.show(file, tags: ["Red"], isCut: true)
        #expect(list.imageView?.alphaValue == 0.5)
        #expect(list.textField?.alphaValue == 0.5)
        #expect(descendant(TagDotsView.self, in: list.view)?.alphaValue == 0.5)
        #expect(list.view.alphaValue == 1)
        list.show(file, tags: ["Blue"])
        #expect(list.imageView?.alphaValue == (hidden ? 0.55 : 1))
        #expect(list.textField?.alphaValue == (hidden ? 0.55 : 1))
        #expect(descendant(TagDotsView.self, in: list.view)?.alphaValue == 1)
        #expect(list.isSelected)
    }

    @Test(arguments: [ViewMode.details, .list, .icons, .gallery])
    func sharedClipboardUpdatesBothWindowsAndNewViews(mode: ViewMode) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let cut = CutPasteboard(pasteboard: pasteboard)
        let first = makeFixture(mode: mode, cut: cut)
        let second = makeFixture(mode: mode, cut: cut)
        defer {
            first.close()
            second.close()
        }
        try await first.load()
        try await second.load()
        let file = try #require(first.model.items.first)
        #expect(first.controller.select([file.url], scroll: true))
        #expect(second.controller.select([file.url], scroll: true))
        first.controller.view.layoutSubtreeIfNeeded()
        second.controller.view.layoutSubtreeIfNeeded()
        cut.write([file.url], cut: true)
        #expect(try first.iconAlpha(for: file.url) == 0.5)
        #expect(try second.iconAlpha(for: file.url) == 0.5)
        #expect(first.controller.selectedItems.map(\.url) == [file.url])
        #expect(second.controller.selectedItems.map(\.url) == [file.url])
        // A thumbnail completing after Cut must reconfigure with current state.
        NotificationCenter.default.post(name: ThumbnailCache.didLoad, object: file.url)
        #expect(try first.iconAlpha(for: file.url) == 0.5)
        let newView = makeFixture(mode: mode, cut: cut)
        defer { newView.close() }
        try await newView.load()
        #expect(newView.controller.select([file.url], scroll: true))
        newView.controller.view.layoutSubtreeIfNeeded()
        #expect(try newView.iconAlpha(for: file.url) == 0.5)
        pasteboard.clearContents()
        pasteboard.setString("New clipboard", forType: .string)
        cut.validate()
        #expect(try first.iconAlpha(for: file.url) == 1)
        #expect(try second.iconAlpha(for: file.url) == 1)
        #expect(try newView.iconAlpha(for: file.url) == 1)
        #expect(first.controller.selectedItems.map(\.url) == [file.url])
    }

    @Test func detailsKeepsExpandedFoldersAndFadesMetadata() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let cut = CutPasteboard(pasteboard: pasteboard)
        let fixture = makeFixture(mode: .details, cut: cut)
        defer { fixture.close() }
        try await fixture.load()
        let controller = try #require(fixture.controller as? FileListViewController)
        let node = try #require(controller.roots.first { $0.item.name == "Sources" })
        controller.outlineView.expandItem(node)
        try await waitUntil { node.children?.isEmpty == false }
        let file = try #require(node.children?.first?.item)
        #expect(controller.select([file.url], scroll: true))
        cut.write([file.url], cut: true)
        #expect(controller.outlineView.isItemExpanded(node))
        #expect(try fixture.iconAlpha(for: file.url) == 0.5)
        let row = controller.outlineView.selectedRow
        let column = try #require(
            controller.outlineView.tableColumns.indices.first {
                !controller.outlineView.tableColumns[$0].isHidden
                    && controller.outlineView.tableColumns[$0].identifier
                        != FileListViewController.Column.name.identifier
            })
        let metadata = try #require(controller.outlineView.view(atColumn: column, row: row, makeIfNecessary: true))
        #expect(metadata.alphaValue == 0.5)
        cut.invalidate()
        #expect(metadata.alphaValue == 1)
        #expect(controller.outlineView.isItemExpanded(node))
        #expect(controller.selectedItems.map(\.url) == [file.url])
    }

    @Test func columnsKeepDeeperSelectionAndResetReusedCells() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let cut = CutPasteboard(pasteboard: pasteboard)
        let fixture = makeFixture(mode: .columns, cut: cut)
        defer { fixture.close() }
        try await fixture.load()
        let sources = folder.appendingPathComponent("Sources")
        let leaf = sources.appendingPathComponent("ScopeEngine")
        #expect(fixture.controller.select([sources], scroll: false))
        try await waitUntil { fixture.controller.select([leaf], scroll: false) }
        let browser = try #require(fixture.controller.view as? NSBrowser)
        browser.display()
        let lastColumn = browser.lastColumn
        cut.write([sources, leaf], cut: true)
        browser.display()
        #expect(browser.lastColumn == lastColumn)
        #expect(fixture.controller.selectedItems.map(\.url.path) == [leaf.path])
        let controller = try #require(fixture.controller as? ColumnViewController)
        let cell = CutBrowserCell(textCell: "")
        let row = browser.selectedRow(inColumn: 1)
        controller.browser(browser, willDisplayCell: cell, atRow: row, column: 1)
        #expect(cell.isCut)
        cut.invalidate()
        controller.browser(browser, willDisplayCell: cell, atRow: row, column: 1)
        #expect(!cell.isCut)
        #expect(browser.lastColumn == lastColumn)
        #expect(fixture.controller.selectedItems.map(\.url.path) == [leaf.path])
        #expect(browser.cellPrototype is CutBrowserCell)
    }

    @Test(arguments: [false, true], [NSAppearance.Name.aqua.rawValue, NSAppearance.Name.darkAqua.rawValue])
    func columnDrawingFadesAttachmentsAndPreservesSelection(selected: Bool, appearance: String) throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        view.appearance = NSAppearance(named: NSAppearance.Name(appearance))
        let cell = CutBrowserCell(textCell: "")
        cell.isLeaf = true
        cell.isHighlighted = selected
        cell.state = selected ? .on : .off
        let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = icon
        attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
        let label = NSMutableAttributedString(attachment: attachment)
        label.append(NSAttributedString(string: "  Cut item"))
        cell.attributedStringValue = label
        func render(cut: Bool) throws -> NSBitmapImageRep {
            let bitmap = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 24, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            cell.isCut = cut
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.white.setFill()
                view.bounds.fill()
                cell.draw(withFrame: view.bounds, in: view)
            }
            return bitmap
        }
        let normal = try render(cut: false)
        let faded = try render(cut: true)
        // Find a solid attachment pixel, rather than depending on text antialiasing.
        var attachmentPixel: (Int, Int)?
        for y in 0..<24 {
            for x in 0..<30 {
                let color = try #require(normal.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.redComponent > 0.95 && color.greenComponent < 0.05 && color.blueComponent < 0.05 {
                    attachmentPixel = (x, y)
                }
            }
        }
        let pixel = try #require(attachmentPixel)
        let fadedColor = try #require(faded.colorAt(x: pixel.0, y: pixel.1)?.usingColorSpace(.deviceRGB))
        #expect(fadedColor.greenComponent > 0.1 || fadedColor.blueComponent > 0.1)
        #expect(normal.colorAt(x: 190, y: 12) == faded.colorAt(x: 190, y: 12))
    }

    private func makeFixture(mode: ViewMode, cut: CutPasteboard) -> CutViewFixture {
        let model = BrowserModel(engine: FileEngine(pathGuard: .readOnly), location: .folder(folder))
        let cache = FileTagCache { _ in [] }
        let controller: any FileBrowsingView
        switch mode {
        case .details: controller = FileListViewController(model: model, tagCache: cache, cutPasteboard: cut)
        case .list: controller = IconGridViewController(model: model, style: .list, tagCache: cache, cutPasteboard: cut)
        case .icons:
            controller = IconGridViewController(model: model, style: .grid, tagCache: cache, cutPasteboard: cut)
        case .gallery: controller = GalleryViewController(model: model, tagCache: cache, cutPasteboard: cut)
        case .columns: controller = ColumnViewController(model: model, tagCache: cache, cutPasteboard: cut)
        }
        return CutViewFixture(model: model, controller: controller)
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

@MainActor private struct CutViewFixture {
    let model: BrowserModel
    let controller: any FileBrowsingView
    let window: NSWindow

    init(model: BrowserModel, controller: any FileBrowsingView) {
        self.model = model
        self.controller = controller
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        model.onChange = { [weak controller] in controller?.modelDidChange($0) }
    }

    func load() async throws {
        for _ in 0..<500 {
            if model.state == .loaded {
                controller.view.layoutSubtreeIfNeeded()
                controller.view.displayIfNeeded()
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.state == .loaded)
    }

    func iconAlpha(for url: URL) throws -> CGFloat {
        if let details = controller as? FileListViewController {
            let row = details.outlineView.selectedRow
            let cell = try #require(
                details.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileNameCell)
            return try #require(cell.imageView).alphaValue
        }
        let collection = try #require(descendant(in: controller.view))
        let index = try #require(model.items.firstIndex { $0.url == url })
        let item = try #require(collection.item(at: IndexPath(item: index, section: 0)))
        return try #require(item.imageView).alphaValue
    }

    private func descendant(in view: NSView) -> NSCollectionView? {
        if let collection = view as? NSCollectionView { return collection }
        return view.subviews.lazy.compactMap { descendant(in: $0) }.first
    }

    func close() {
        controller.close()
        model.close()
        window.close()
    }
}
