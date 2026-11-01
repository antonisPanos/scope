import AppKit
import os
import ScopeEngine
import Quartz
import SwiftUI

/// One browser window. Each window is a tab in macOS's native window tabs, so
/// Cmd+T, the tab bar, dragging tabs out and Merge All Windows behave as
/// everywhere else on the Mac. Split view puts two panes side by side, each
/// with its own tabs; commands act on the pane that has focus.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let workspace: WorkspaceController
    /// The tab with focus: in the focused pane, its visible tab.
    private var content: BrowserViewController { workspace.activeContent }
    var model: BrowserModel { content.model }
    private var firstResponderObservation: NSKeyValueObservation?
    /// Whether the preview pane was showing before split view hid it.
    private var previewBeforeSplit = true
    private let splitController = NSSplitViewController()
    private let sidebarSelection = SidebarSelection()
    private var sidebarItem: NSSplitViewItem!
    private var palette: CommandPalette?
    private let contextMenu = NSMenu()
    private let contextMenuBuilder = ContextMenuBuilder()
    private var navigationGroup: NSToolbarItemGroup?
    private var viewModeGroup: NSToolbarItemGroup?
    /// Called when the tab closes, so the app can let it go.
    var onClose: ((BrowserWindowController) -> Void)?

    private static let logger = Logger(subsystem: "com.antonispanos.scope", category: "Browser")
    private static let navigationItem = NSToolbarItem.Identifier("navigation")
    private static let viewModeItem = NSToolbarItem.Identifier("viewMode")
    private static let paletteItem = NSToolbarItem.Identifier("palette")
    private static let activityItem = NSToolbarItem.Identifier("activity")
    private static let searchItem = NSToolbarItem.Identifier("search")
    private static let previewItem = NSToolbarItem.Identifier("preview")
    private var searchToolbarItem: NSSearchToolbarItem?
    private var searchDebounce: Task<Void, Never>?

    init(location: Location) {
        let first = BrowserViewController(model: BrowserModel(engine: BuildIdentity.current.makeEngine(), location: location))
        workspace = WorkspaceController(pane: PaneController(tab: first))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "ScopeBrowser"
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
        let contentItem = NSSplitViewItem(viewController: workspace)
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

        contextMenu.delegate = contextMenuBuilder
        contextMenuBuilder.controller = self
        wire(first)
        wire(workspace.panes[0])
        sidebarSelection.onSelect = { [weak self] item in self?.model.navigate(to: item.location) }
        sidebarSelection.onEject = { [weak self] item in SidebarStore.shared.eject(item, presentingIn: self?.window) }
        // Focus decides which pane commands act on.
        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, let view = window.firstResponder as? NSView else { return }
                if self.workspace.activate(containing: view) { self.activeContentChanged() }
            }
        }
        windowUpdate(.location)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Connects one tab's views and model to the window.
    private func wire(_ tab: BrowserViewController) {
        tab.model.onChange = { [weak self, weak tab] change in
            guard let self, let tab else { return }
            tab.update(change)
            if change.contains(.location) { self.workspace.pane(containing: tab)?.refreshStrip() }
            if tab === self.content { self.windowUpdate(change) }
        }
        tab.onOpen = { [weak self] items in self?.open(items) }
        tab.onQuickLook = { [weak self] in self?.toggleQuickLook() }
        tab.onSelectionChange = { [weak self] in self?.quickLookSelectionChanged() }
        tab.onDrop = { [weak self] urls, folder, copy in self?.handleDrop(urls, onto: folder, copy: copy) }
        tab.onRename = { [weak self] in
            guard let self, self.allowsWrites else { return }
            self.renameSelection()
        }
        tab.onShowActivity = { [weak self] in self?.showActivity(true) }
        tab.onShortcut = { [weak self] action in
            guard let self else { return }
            switch action {
            case .back: self.model.goBack()
            case .forward: self.model.goForward()
            case .reload: self.model.reload()
            case .trash: if self.allowsWrites { self.trashSelection() }
            case .open: self.openSelection()
            case .rename: if self.allowsWrites { self.renameSelection() }
            case .quickLook: self.toggleQuickLook()
            }
        }
        tab.onSearchChange = { [weak self] in self?.runSearch() }
        tab.onEndSearch = { [weak self] in self?.endSearch() }
        tab.onUndoOperation = { [weak self] id in
            let window = self?.window
            Task { await OperationsController.shared.undo(id, from: window) }
        }
        tab.contextMenu = contextMenu
        tab.pathBar.onNavigate = { [weak tab] url in tab?.model.navigate(to: .folder(url)) }
        tab.pathBar.onSubmit = { [weak self] text in
            self?.goToTypedPath(text)
            return nil
        }
    }

    private func wire(_ pane: PaneController) {
        pane.onActivate = { [weak self] pane in
            guard let self, let index = self.workspace.panes.firstIndex(where: { $0 === pane }) else { return }
            self.workspace.activate(index)
            self.activeContentChanged()
        }
        pane.onNewTab = { [weak self] pane in self?.addTab(to: pane) }
        pane.onCloseTab = { [weak self] pane, index in self?.closeTab(in: pane, at: index) }
    }

    /// Refreshes everything that follows the focused tab: title, sidebar, toolbar, search field.
    private func activeContentChanged() {
        searchToolbarItem?.searchField.stringValue = content.model.location.isSearch ? content.search.text : ""
        windowUpdate([.location, .viewMode])
    }

    private func windowUpdate(_ change: BrowserModel.Change) {
        if change.contains(.location) {
            if !model.location.isSearch, searchToolbarItem?.searchField.stringValue.isEmpty == false,
               searchToolbarItem?.searchField.currentEditor() == nil {
                searchToolbarItem?.searchField.stringValue = ""
                content.search.reset()
            }
            window?.title = model.location.title
            window?.subtitle = ""
            sidebarSelection.selectedID = SidebarStore.shared.item(for: model.location)?.id
        }
        if change.contains(.viewMode) || change.contains(.location) { updateToolbar() }
    }

    // MARK: - Split view and pane tabs

    var isSplit: Bool { workspace.isSplit }

    /// Shows a second pane beside the first, at the same folder, or closes it.
    /// The preview pane hides while split is on.
    func toggleSplit() {
        if workspace.isSplit {
            if let removed = workspace.removeRightPane() {
                if let item = splitController.splitViewItems.first(where: { $0.viewController === removed }) {
                    splitController.removeSplitViewItem(item)
                }
                for tab in removed.tabs { tab.close(); tab.model.close() }
            }
            content.isPreviewVisible = previewBeforeSplit
            activeContentChanged()
        } else {
            previewBeforeSplit = content.isPreviewVisible
            let tab = makeTab(at: model.location)
            let pane = PaneController(tab: tab)
            wire(pane)
            workspace.addPane(pane)
            let item = NSSplitViewItem(viewController: pane)
            item.titlebarSeparatorStyle = .line
            splitController.addSplitViewItem(item)
            let split = splitController.splitView
            split.adjustSubviews()
            let left = sidebarItem.isCollapsed ? 0 : sidebarItem.viewController.view.frame.width
            split.setPosition(left + (split.bounds.width - left) / 2, ofDividerAt: 1)
            for tab in workspace.allContents { tab.isPreviewVisible = false }
            workspace.activate(1)
            activeContentChanged()
            tab.fileView.focus()
        }
    }

    private func makeTab(at location: Location) -> BrowserViewController {
        let tab = BrowserViewController(model: BrowserModel(engine: BuildIdentity.current.makeEngine(), location: location))
        wire(tab)
        _ = tab.view
        if workspace.isSplit { tab.isPreviewVisible = false }
        return tab
    }

    private func addTab(to pane: PaneController) {
        let tab = makeTab(at: pane.activeTab.model.location)
        if workspace.isSplit { tab.isPreviewVisible = false }
        pane.addTab(tab)
    }

    private func closeTab(in pane: PaneController, at index: Int) {
        if let removed = pane.removeTab(at: index) {
            removed.close()
            removed.model.close()
        }
    }

    /// Cmd+W: in split view closes the focused pane's tab while it has more
    /// than one, then ends split view (keeping the left side); otherwise
    /// closes the window.
    @objc func closeTabOrWindow(_ sender: Any?) {
        if workspace.isSplit {
            let pane = workspace.activePane
            if pane.tabs.count > 1 {
                closeTab(in: pane, at: pane.activeIndex)
            } else {
                toggleSplit()
            }
        } else {
            window?.performClose(sender)
        }
    }

    /// Moves focus to the left (0) or right (1) pane.
    func focusPane(_ index: Int) {
        guard workspace.panes.indices.contains(index) else { return }
        workspace.activate(index)
        activeContentChanged()
        content.fileView.focus()
    }

    /// The folder shown in the other pane, for copying or moving across.
    var otherPaneFolder: URL? {
        workspace.otherPane?.activeTab.model.location.folderURL
    }

    func transferToOtherPane(move: Bool) {
        let urls = selectedItems.map(\.url)
        guard let folder = otherPaneFolder, !urls.isEmpty else { return }
        startOperation(move ? .move(urls, into: folder) : .copy(urls, into: folder))
    }

    private func updateToolbar() {
        navigationGroup?.subitems[0].isEnabled = model.canGoBack
        navigationGroup?.subitems[1].isEnabled = model.canGoForward
        viewModeGroup?.selectedIndex = ViewMode.allCases.firstIndex(of: model.viewMode) ?? 0
    }

    func focusFileList() {
        content.fileView.focus()
    }

    // MARK: - Tabs and windows

    override func newWindowForTab(_ sender: Any?) {
        // In split view, Cmd+T opens a tab on the focused side.
        if workspace.isSplit {
            addTab(to: workspace.activePane)
            return
        }
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
        firstResponderObservation = nil
        for tab in workspace.allContents {
            tab.close()
            tab.model.close()
        }
        onClose?(self)
    }

    // MARK: - Commands

    @objc func runCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let command = Commands.command(id: id),
              command.isEnabled(self) else { return }
        // A held-down Cmd+Delete or Cmd+V must not fire again and again.
        if command.ignoresKeyRepeat, NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.isARepeat == true { return }
        command.run(self)
    }

    /// False in the read-only release build.
    var allowsWrites: Bool { model.engine.pathGuard.allowsWrites }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): return !selectedItems.isEmpty
        case #selector(paste(_:)): return !pasteboardFiles.isEmpty && currentFolder != nil && allowsWrites
        case #selector(undo(_:)):
            menuItem.title = "Undo"
            return OperationsController.shared.canUndo
        default: break
        }
        guard menuItem.action == #selector(runCommand(_:)) else { return true }
        guard let id = menuItem.representedObject as? String, let command = Commands.command(id: id) else { return false }
        menuItem.state = command.isChecked?(self) == true ? .on : .off
        return command.isEnabled(self)
    }

    var selectedItems: [FileItem] { content.fileView.selectedItems }

    #if SCOPE_DEV
    func selectForHooks(_ urls: [URL]) {
        content.fileView.select(urls, scroll: true)
    }

    /// "search:<mode>:<text>" with mode contains, glob, regex or contents.
    func searchForHooks(_ argument: String) {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let mode = SearchSettings.Mode(rawValue: parts[0]) else { return }
        content.search.mode = mode
        content.search.text = parts[1]
        searchToolbarItem?.searchField.stringValue = parts[1]
        runSearch()
    }

    var searchSettingsForHooks: SearchSettings { content.search }

    func logPanesForHooks() {
        if let window {
            Self.logger.notice("Window content layout \(NSStringFromRect(window.contentLayoutRect), privacy: .public), frame \(NSStringFromRect(window.frame), privacy: .public), accessories \(window.titlebarAccessoryViewControllers.count), tab bar \(window.tabGroup?.isTabBarVisible ?? false)")
            for tab in workspace.allContents {
                let bar = tab.pathBar
                Self.logger.notice("Path bar \(NSStringFromRect(bar.convert(bar.bounds, to: nil)), privacy: .public) hidden \(bar.isHidden) safe top \(tab.view.safeAreaInsets.top)")
            }
        }
        for (index, pane) in workspace.panes.enumerated() {
            Self.logger.notice("Pane \(index)\(index == self.workspace.activePaneIndex ? " (focused)" : ""): tabs \(pane.strip.titles.joined(separator: " | "), privacy: .public), active \(pane.activeIndex), strip \(pane.showsTabStrip), frame \(NSStringFromRect(pane.view.frame), privacy: .public)")
        }
    }
    #endif

    func prepareForContextMenu() {
        content.fileView.prepareForContextMenu()
    }

    func openSelection() {
        open(selectedItems)
    }

    var isPathBarVisible: Bool { content.isPathBarVisible }
    var isStatusBarVisible: Bool { content.isStatusBarVisible }
    var isSidebarVisible: Bool { !sidebarItem.isCollapsed }
    var isPreviewVisible: Bool { content.isPreviewVisible }
    var isActivityVisible: Bool { content.isActivityVisible }
    func showActivity(_ visible: Bool) {
        content.isActivityVisible = visible
        OperationsController.shared.drawerVisible = visible
        if visible { OperationsController.shared.markAllRead() }
    }
    func togglePreview() { content.isPreviewVisible.toggle() }

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
                showProblem("“\(url.lastPathComponent)” points to \(target.path), outside the test disks. Scope Dev won't follow it.")
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
            showProblem("\(url.path) is outside the test disks, so Scope Dev won't open it.")
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
            showProblem("\(url.path) is outside the test disks, so Scope Dev won't open it.")
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
        [.toggleSidebar, .sidebarTrackingSeparator, Self.navigationItem, .flexibleSpace, Self.activityItem, Self.viewModeItem,
         Self.previewItem, Self.paletteItem, Self.searchItem]
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
        case Self.activityItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Activity"
            item.toolTip = "Activity (⌥⌘A)"
            item.view = NSHostingView(rootView: ActivityRing(controller: OperationsController.shared) { [weak self] in
                guard let self else { return }
                self.showActivity(!self.isActivityVisible)
            })
            return item
        case Self.previewItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Details Panel")
            item.label = "Details"
            item.toolTip = "Show or Hide the Details Panel (⇧⌘P)"
            item.target = self
            item.action = #selector(previewClicked)
            return item
        case Self.searchItem:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField.placeholderString = "Search"
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = false
            item.searchField.focusRingType = .none
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldChanged(_:))
            item.preferredWidthForSearchField = 200
            searchToolbarItem = item
            return item
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

    @objc private func previewClicked() {
        togglePreview()
    }

    @objc private func paletteClicked() {
        showCommandPalette()
    }
}

// MARK: - Search

extension BrowserWindowController: NSSearchFieldDelegate {
    /// Cmd+F: put the cursor in the search field.
    func beginSearch() {
        searchToolbarItem?.beginSearchInteraction()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === searchToolbarItem?.searchField else { return }
        // Wait for a pause in typing before crawling.
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.content.search.text = field.stringValue
            self.runSearch()
        }
    }

    @objc func searchFieldChanged(_ sender: NSSearchField) {
        searchDebounce?.cancel()
        content.search.text = sender.stringValue
        runSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchToolbarItem?.searchField else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            endSearch()
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)):
            // Return or Down moves into the results.
            focusFileList()
            return true
        default:
            return false
        }
    }

    /// Searches the folder on screen (or the folder the current search is in)
    /// with the field's text and the filter bar's settings.
    func runSearch() {
        let query = content.search.query
        guard let root = model.location.searchRoot else { return }
        if query.isEmpty && !model.location.isSearch { return }
        if query.text.trimmingCharacters(in: .whitespaces).isEmpty && query.isEmpty {
            endSearch()
            return
        }
        let destination = Location.search(query, in: root)
        if model.location.isSearch {
            model.replace(with: destination)
        } else {
            model.navigate(to: destination)
        }
    }

    /// Back to the folder that was searched.
    func endSearch() {
        searchDebounce?.cancel()
        searchToolbarItem?.searchField.stringValue = ""
        content.search.reset()
        guard case .search(_, let root) = model.location else { return }
        model.replace(with: .folder(root))
        focusFileList()
    }

    /// Escape stops a running search, then ends it.
    override func cancelOperation(_ sender: Any?) {
        if model.isSearching {
            model.stopSearch()
        } else if model.location.isSearch {
            endSearch()
        }
    }
}
