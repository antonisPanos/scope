import AppKit
import Foundation
import QuartzCore
import Testing

@testable import Scope
@testable import ScopeEngine

@MainActor struct TagIndicatorTests {
    @Test(arguments: [16.0, 64.0, 128.0], [false, true])
    func iconAndGalleryBadgesKeepTheImageAndClearOnReuse(size: Double, showsName: Bool) async throws {
        let engine = FileEngine(pathGuard: .readOnly)
        let file = try await engine.item(at: URL(fileURLWithPath: #filePath))
        let image = try #require(NSImage(systemSymbolName: "photo.fill", accessibilityDescription: "Test image"))
        let item = IconItem()
        _ = item.view
        item.view.frame = NSRect(x: 0, y: 0, width: max(size + 24, 84), height: size + 46)
        item.show(file, image: image, iconSize: size, showsName: showsName, tags: ColorTags.names)
        item.view.layoutSubtreeIfNeeded()
        let dots = try #require(descendant(TagDotsView.self, in: item.view))
        #expect(!dots.isHidden)
        #expect(dots.accessibilityLabel()?.contains("Red") == true)
        #expect(item.imageView?.image === image)
        let frame = dots.convert(dots.bounds, to: item.view)
        #expect(item.view.bounds.contains(frame))
        item.isSelected = true
        #expect(!dots.isHidden)
        item.show(file, image: image, iconSize: size, showsName: showsName)
        #expect(dots.isHidden)
    }

    @Test func tagAttachmentsRetainAllColoursWhenTheColumnTextIsTruncated() throws {
        let dots = try #require(TagDotsView.attachment(for: ["Red", "Blue", "Work"]))
        let attachment = try #require(dots.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.bounds.width > 10)
        #expect(attachment.image != nil)
        #expect(TagDotsView.attachment(for: ["Work"]) == nil)
    }

    @Test(arguments: [NSAppearance.Name.aqua.rawValue, NSAppearance.Name.darkAqua.rawValue])
    func badgesRemainReadableInBothAppearances(appearance: String) async throws {
        let engine = FileEngine(pathGuard: .readOnly)
        let file = try await engine.item(at: URL(fileURLWithPath: #filePath))
        let folder = try await engine.item(at: URL(fileURLWithPath: #filePath).deletingLastPathComponent())
        let scene = TagPreviewBackground(frame: NSRect(x: 0, y: 0, width: 500, height: 185))
        scene.appearance = try #require(NSAppearance(named: NSAppearance.Name(appearance)))
        let window = NSWindow(contentRect: scene.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = scene.appearance
        window.contentView = scene
        defer { window.close() }
        var items: [IconItem] = []
        for (index, entry) in [folder, file, file].enumerated() {
            let item = IconItem()
            _ = item.view
            item.view.frame = NSRect(x: 15 + index * 160, y: 25, width: 145, height: 145)
            scene.addSubview(item.view)
            item.show(
                entry, image: IconCache.shared.icon(for: entry), iconSize: index == 2 ? 56 : 96,
                showsName: index != 2, tags: index == 2 ? ColorTags.names : ["Red", "Blue"])
            item.isSelected = index == 1
            items.append(item)
        }
        scene.layoutSubtreeIfNeeded()
        scene.displayIfNeeded()
        CATransaction.flush()
        let bitmap = try #require(scene.bitmapImageRepForCachingDisplay(in: scene.bounds))
        scene.cacheDisplay(in: scene.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "tag-badges-\(appearance).png")
        #expect(items.count == 3)
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }
}

@MainActor
private final class TagPreviewBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
