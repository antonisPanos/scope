import AppKit
import ScopeEngine
import Testing

@testable import Scope

@MainActor
struct NavigationToolbarTests {
    @Test func forwardRequiresBackAndRemainsCorrectAcrossWindowUpdates() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let first = BrowserModel(engine: FileEngine(pathGuard: .readOnly), location: .folder(root))
        let second = BrowserModel(engine: FileEngine(pathGuard: .readOnly), location: .folder(root))
        let host = ToolbarHost(model: first)
        defer {
            host.window.close()
            first.close()
            second.close()
        }
        try #require(host.window.toolbar?.visibleItems?.contains(host.group) == true)
        try await check(host, back: false, forward: false)
        first.navigate(to: .folder(root.appendingPathComponent("Scope")))
        try await check(host, back: true, forward: false)
        first.navigate(to: .folder(root.appendingPathComponent("Scope/Browser")))
        try await check(host, back: true, forward: false)
        first.goBack()
        try await check(host, back: true, forward: true)
        first.goBack()
        try await check(host, back: false, forward: true)
        first.goForward()
        try await check(host, back: true, forward: true)
        first.goForward()
        try await check(host, back: true, forward: false)
        first.goBack()
        // Choosing the current sidebar item is not a new navigation.
        first.navigate(to: first.location)
        try await check(host, back: true, forward: true)
        first.navigate(to: .folder(root.appendingPathComponent("ScopeTests")))
        try await check(host, back: true, forward: false)
        let destination = first.location
        first.goForward()
        #expect(first.location == destination)
        try await check(host, back: true, forward: false)
        // A different focused tab has its own independent history.
        second.navigate(to: .folder(root.appendingPathComponent("Packages")))
        second.goBack()
        host.model = second
        try await check(host, back: false, forward: true)
        host.model = first
        try await check(host, back: true, forward: false)
    }

    private func check(
        _ host: ToolbarHost, back: Bool, forward: Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        // Push the history state just as the browser window does, then let
        // actual AppKit window-update cycles try to validate the toolbar.
        host.group.subitems[0].isEnabled = host.model.canGoBack
        host.group.subitems[1].isEnabled = host.model.canGoForward
        for _ in 0..<3 {
            #expect(host.group.subitems[0].isEnabled == back, sourceLocation: sourceLocation)
            #expect(host.group.subitems[1].isEnabled == forward, sourceLocation: sourceLocation)
            NSApp.updateWindows()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(host.group.subitems[0].isEnabled == back, sourceLocation: sourceLocation)
        #expect(host.group.subitems[1].isEnabled == forward, sourceLocation: sourceLocation)
    }
}

@MainActor
private final class ToolbarHost: NSObject, NSToolbarDelegate {
    var model: BrowserModel
    let window: NSWindow
    lazy var group = BrowserWindowController.makeNavigationGroup(target: self, action: #selector(navigate(_:)))

    init(model: BrowserModel) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init()
        let toolbar = NSToolbar(identifier: .init("NavigationToolbarTests-" + UUID().uuidString))
        toolbar.delegate = self
        window.toolbar = toolbar
        window.orderBack(nil)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [group.itemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [group.itemIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        group
    }

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { model.goBack() } else { model.goForward() }
    }
}
