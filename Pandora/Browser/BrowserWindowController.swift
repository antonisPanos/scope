import AppKit
import os
import PandoraEngine
import SwiftUI

/// One browser tab. Each tab is its own window, grouped with the others by
/// macOS's native window tabs, so Cmd+T, the tab bar, dragging tabs out and
/// Merge All Windows all behave as everywhere else on the Mac.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: BrowserModel
    private let content: BrowserViewController
    private let splitController = NSSplitViewController()
    private let sidebarSelection = SidebarSelection()
    private var sidebarItem: NSSplitViewItem!
    private var palette: CommandPalette?
    private var navigationGroup: NSToolbarItemGroup?
    private var viewModeGroup: NSToolbarItemGroup?
    /// Called when the tab closes, so the app can let it go.
    var onClose: ((BrowserWindowController) -> Void)?

    private static let logger = Logger(subsystem: "com.antonispanos.pandora", category: "Browser")
    private static let navigationItem = NSToolbarItem.Identifier("navigation")
    private static let viewModeItem = NSToolbarItem.Identifier("viewMode")
    private static let paletteItem = NSToolbarItem.Identifier("palette")

    init(location: Location) {
        model = BrowserModel(engine: BuildIdentity.current.makeEngine(), location: location)
        content = BrowserViewController(model: model)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "PandoraBrowser"
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 560, height: 320)
        window.backgroundColor = Palette.windowBackground
        super.init(window: window)
        window.delegate = self

        let sidebar = NSHostingController(rootView: SidebarView(store: SidebarStore.shared, selection: sidebarSelection))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.titlebarSeparatorStyle = .line
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        splitController.splitView.autosaveName = "BrowserSplit"
        window.contentViewController = splitController
        window.setContentSize(NSSize(width: 1000, height: 620))

        let toolbar = NSToolbar(identifier: "BrowserToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        wireUp()
        update(.location)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func wireUp() {
        model.onChange = { [weak self] change in self?.update(change) }
        content.fileList.onOpen = { [weak self] items in self?.open(items) }
        content.fileList.onSelectionChange = { [weak self] in self?.content.updateStatus() }
        content.pathBar.onNavigate = { [weak self] url in self?.model.navigate(to: .folder(url)) }
        content.pathBar.onSubmit = { [weak self] text in
            self?.goToTypedPath(text)
            return nil
        }
        sidebarSelection.onSelect = { [weak self] item in self?.model.navigate(to: item.location) }
        sidebarSelection.onEject = { [weak self] item in SidebarStore.shared.eject(item, presentingIn: self?.window) }
    }

    private func update(_ change: BrowserModel.Change) {
        content.update(change)
        if change.contains(.location) {
            window?.title = model.location.title
            window?.subtitle = ""
            sidebarSelection.selectedID = SidebarStore.shared.item(for: model.location)?.id
        }
        if change.contains(.viewMode) || change.contains(.location) { updateToolbar() }
    }

    private func updateToolbar() {
        navigationGroup?.subitems[0].isEnabled = model.canGoBack
        navigationGroup?.subitems[1].isEnabled = model.canGoForward
        viewModeGroup?.selectedIndex = ViewMode.allCases.firstIndex(of: model.viewMode) ?? 0
    }

    func focusFileList() {
        content.fileList.focus()
    }

    // MARK: - Tabs and windows

    override func newWindowForTab(_ sender: Any?) {
        guard let window, let app = NSApp.delegate as? AppDelegate else { return }
        let tab = app.makeBrowser(location: model.location)
        if let tabWindow = tab.window {
            window.addTabbedWindow(tabWindow, ordered: .above)
            tabWindow.makeKeyAndOrderFront(nil)
        }
        tab.focusFileList()
    }

    func windowWillClose(_ notification: Notification) {
        palette?.close()
        model.close()
        onClose?(self)
    }

    // MARK: - Commands

    @objc func runCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let command = Commands.command(id: id),
              command.isEnabled(self) else { return }
        command.run(self)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(runCommand(_:)) else { return true }
        guard let id = menuItem.representedObject as? String, let command = Commands.command(id: id) else { return false }
        menuItem.state = command.isChecked?(self) == true ? .on : .off
        return command.isEnabled(self)
    }

    var selectedItems: [FileItem] { content.fileList.selectedItems }

    func openSelection() {
        open(selectedItems)
    }

    var isPathBarVisible: Bool { content.isPathBarVisible }
    var isStatusBarVisible: Bool { content.isStatusBarVisible }
    var isSidebarVisible: Bool { !sidebarItem.isCollapsed }

    func togglePathBar() { content.isPathBarVisible.toggle() }
    func toggleStatusBar() { content.isStatusBarVisible.toggle() }
    func toggleSidebar() { sidebarItem.animator().isCollapsed.toggle() }

    func beginTypingPath() {
        if !content.isPathBarVisible { content.isPathBarVisible = true }
        content.pathBar.beginEditing()
    }

    func showCommandPalette() {
        if palette == nil { palette = CommandPalette(controller: self) }
        palette?.show()
    }

    /// The folder "Add to Sidebar" would add: the selected folder, or the current one.
    var folderToAddToSidebar: URL? {
        if let folder = selectedItems.first(where: \.isBrowsableFolder) { return folder.url }
        return model.location.folderURL
    }

    func addSelectionToSidebar() {
        guard let url = folderToAddToSidebar else { return }
        SidebarStore.shared.addFavorite(url)
    }

    /// Cmd+E ejects the selected volume in the list, or the disk being shown
    /// when the tab is at a disk's top level.
    var volumeToEject: SidebarItem? {
        let candidates = selectedItems.map(\.url) + [model.location.folderURL].compactMap { $0 }
        for url in candidates {
            if let item = (SidebarStore.shared.locations + SidebarStore.shared.diskImages)
                .first(where: { $0.volumeURL?.standardizedFileURL == url.standardizedFileURL && $0.canEject && $0.isEnabled }) {
                return item
            }
        }
        return nil
    }

    func ejectSelectedVolume() {
        guard let item = volumeToEject else { return }
        SidebarStore.shared.eject(item, presentingIn: window)
    }

    // MARK: - Opening

    /// Opens items: folders in this tab (extra folders in new tabs), symlinks
    /// and aliases by following them, files in their default app. Every target
    /// must pass the path guard first.
    func open(_ items: [FileItem]) {
        var openedFolderHere = false
        for item in items {
            if item.isBrowsableFolder && !item.isSymbolicLink {
                openFolder(item.url, inNewTab: openedFolderHere)
                openedFolderHere = true
            } else if item.isSymbolicLink || item.isAlias {
                followLink(item.url, inNewTab: openedFolderHere)
                openedFolderHere = true
            } else {
                openFile(item.url)
            }
        }
    }

    private func openFolder(_ url: URL, inNewTab: Bool) {
        if inNewTab, let window, let app = NSApp.delegate as? AppDelegate {
            let tab = app.makeBrowser(location: .folder(url))
            if let tabWindow = tab.window { window.addTabbedWindow(tabWindow, ordered: .above) }
        } else {
            model.navigate(to: .folder(url))
        }
    }

    private func followLink(_ url: URL, inNewTab: Bool) {
        let pathGuard = model.engine.pathGuard
        Task {
            let resolved = await Task.detached { () -> (URL, Bool)? in
                guard let target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) else { return nil }
                let isFolder = (try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
                    .map { ($0.isDirectory ?? false) && !($0.isPackage ?? false) } ?? false
                return (target, isFolder)
            }.value
            guard let (target, isFolder) = resolved else {
                showProblem("“\(url.lastPathComponent)” points to an item that doesn't exist.")
                return
            }
            guard pathGuard.permits(target) else {
                showProblem("“\(url.lastPathComponent)” points to \(target.path), outside the test disks. Pandora Dev won't follow it.")
                return
            }
            if isFolder {
                openFolder(target, inNewTab: inNewTab)
            } else {
                openFile(target)
            }
        }
    }

    private func openFile(_ url: URL) {
        guard model.engine.pathGuard.permits(url) else {
            showProblem("\(url.path) is outside the test disks, so Pandora Dev won't open it.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Handles a path typed into the path bar or the command palette.
    func goToTypedPath(_ text: String) {
        guard let url = PathInput.resolve(text, relativeTo: model.location.folderURL, home: BuildIdentity.realHome) else {
            showProblem("“\(text)” isn't a path.")
            return
        }
        let pathGuard = model.engine.pathGuard
        guard pathGuard.permits(url) else {
            showProblem("\(url.path) is outside the test disks, so Pandora Dev won't open it.")
            return
        }
        Task {
            let kind = await Task.detached { () -> Bool? in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return nil }
                return (values.isDirectory ?? false) && !(values.isPackage ?? false)
            }.value
            switch kind {
            case nil:
                showProblem("There's no folder at \(url.path).")
            case true?:
                model.navigate(to: .folder(url))
                focusFileList()
            case false?:
                // A file: show its folder with the file selected.
                model.navigate(to: .folder(url.deletingLastPathComponent()), select: url)
                focusFileList()
            }
        }
    }

    private func showProblem(_ text: String) {
        Self.logger.notice("Problem shown: \(text, privacy: .public)")
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = text
        alert.alertStyle = .informational
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}

// MARK: - Toolbar

extension BrowserWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.navigationItem, .flexibleSpace, Self.viewModeItem, Self.paletteItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.navigationItem:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                         NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!],
                selectionMode: .momentary, labels: ["Back", "Forward"], target: self, action: #selector(navigationClicked(_:)))
            group.label = "Back/Forward"
            group.isNavigational = true
            navigationGroup = group
            updateToolbar()
            return group
        case Self.viewModeItem:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: ViewMode.allCases.map { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: $0.title)! },
                selectionMode: .selectOne, labels: ViewMode.allCases.map(\.title), target: self, action: #selector(viewModeClicked(_:)))
            group.label = "View"
            group.controlRepresentation = .expanded
            viewModeGroup = group
            updateToolbar()
            return group
        case Self.paletteItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Command Palette")
            item.label = "Commands"
            item.toolTip = "Command Palette (⌘K)"
            item.target = self
            item.action = #selector(paletteClicked)
            return item
        default:
            return nil
        }
    }

    @objc private func navigationClicked(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { model.goBack() } else { model.goForward() }
    }

    @objc private func viewModeClicked(_ sender: NSToolbarItemGroup) {
        guard ViewMode.allCases.indices.contains(sender.selectedIndex) else { return }
        model.viewMode = ViewMode.allCases[sender.selectedIndex]
    }

    @objc private func paletteClicked() {
        showCommandPalette()
    }
}
