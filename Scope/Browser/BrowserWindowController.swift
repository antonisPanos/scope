import AppKit
import Quartz
import ScopeEngine
import SwiftUI
import os

/// One browser window. Each window is a tab in macOS's native window tabs, so
/// Cmd+T, the tab bar, dragging tabs out and Merge All Windows behave as
/// everywhere else on the Mac. Split view puts two panes side by side, each
/// with its own tabs; commands act on the pane that has focus.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let workspace: WorkspaceController
    /// The tab with focus: in the focused pane, its visible tab.
    var content: BrowserViewController { workspace.activeContent }
    var model: BrowserModel { content.model }
    private var firstResponderObservation: NSKeyValueObservation?
    /// Whether the preview pane was showing before split view hid it.
    var previewBeforeSplit = true
    let splitController = NSSplitViewController()
    var contentItem: NSSplitViewItem!
    private let sidebarSelection = SidebarSelection()
    var sidebarItem: NSSplitViewItem!
    var palette: CommandPalette?
    private let contextMenu = NSMenu()
    private let contextMenuBuilder = ContextMenuBuilder()
    var navigationGroup: NSToolbarItemGroup?
    var viewModeGroup: NSToolbarItemGroup?
    /// Called when the tab closes, so the app can let it go.
    var onClose: ((BrowserWindowController) -> Void)?

    static let logger = Logger(subsystem: "com.antonispanos.scope", category: "Browser")
    var searchToolbarItem: NSSearchToolbarItem?
    var splitGroup: NSToolbarItemGroup?
    var previewGroup: NSToolbarItemGroup?
    var searchDebounce: Task<Void, Never>?
    var quickLookTask: Task<Void, Never>?
    var quickLookURLs: [URL] = []

    init(location: Location) {
        let first = BrowserViewController(
            model: BrowserModel(
                engine: BuildIdentity.current.makeEngine(), location: location,
                announcements: OperationsController.shared.center.announcements))
        workspace = WorkspaceController(pane: PaneController(tab: first))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
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

        let sidebar = NSHostingController(
            rootView: SidebarView(store: SidebarStore.shared, selection: sidebarSelection))
        // Without this the hosting controller pins the sidebar to its ideal
        // width, and the divider can't be dragged.
        sidebar.sizingOptions = []
        sidebar.view.setContentHuggingPriority(.init(1), for: .horizontal)
        sidebar.view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 400
        sidebarItem.holdingPriority = .init(260)
        sidebarItem.canCollapse = true
        contentItem = NSSplitViewItem(viewController: workspace)
        contentItem.titlebarSeparatorStyle = .line
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        splitController.splitView.autosaveName = "BrowserSplit.v2"
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
        sidebarSelection.onOpenInSplit = { [weak self] item in self?.openInSplit(item.location) }
        sidebarSelection.onOpenInNewTab = { [weak self] item in self?.openInNewTab(item.location) }
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
    func wire(_ tab: BrowserViewController) {
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

    func wire(_ pane: PaneController) {
        pane.onActivate = { [weak self] pane in
            guard let self, let index = self.workspace.panes.firstIndex(where: { $0 === pane }) else { return }
            self.workspace.activate(index)
            self.activeContentChanged()
        }
        pane.onNewTab = { [weak self] pane in self?.addTab(to: pane) }
        pane.onCloseTab = { [weak self] pane, index in self?.closeTab(in: pane, at: index) }
        pane.onTabAction = { [weak self] pane, index, action in self?.tabAction(action, in: pane, at: index) }
    }

    /// Refreshes everything that follows the focused tab: title, sidebar, toolbar, search field.
    func activeContentChanged() {
        searchToolbarItem?.searchField.stringValue = content.model.location.isSearch ? content.search.text : ""
        windowUpdate([.location, .viewMode])
    }

    private func windowUpdate(_ change: BrowserModel.Change) {
        if change.contains(.location) {
            if !model.location.isSearch, searchToolbarItem?.searchField.stringValue.isEmpty == false,
                searchToolbarItem?.searchField.currentEditor() == nil
            {
                searchToolbarItem?.searchField.stringValue = ""
                content.search.reset()
            }
            window?.title = model.location.title
            window?.subtitle = ""
            sidebarSelection.selectedID = SidebarStore.shared.item(for: model.location)?.id
        }
        if change.contains(.viewMode) || change.contains(.location) { updateToolbar() }
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

    /// Zoom (double-clicking the title bar) fills the screen and no more,
    /// with one pane or two.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? newFrame
    }

    func windowWillClose(_ notification: Notification) {
        quickLookTask?.cancel()
        quickLookURLs = []
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
            command.isEnabled(self)
        else { return }
        // A held-down Cmd+Delete or Cmd+V must not fire again and again.
        if command.ignoresKeyRepeat, NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.isARepeat == true {
            return
        }
        command.run(self)
    }

    /// False in the read-only release build.
    var allowsWrites: Bool { model.engine.pathGuard.allowsWrites }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): return !selectedItems.isEmpty
        case #selector(cut(_:)): return AppSettings.shared.commandXCuts && !selectedItems.isEmpty && allowsWrites
        case #selector(paste(_:)): return !pasteboardFiles.isEmpty && currentFolder != nil && allowsWrites
        case #selector(undo(_:)):
            menuItem.title = "Undo"
            return OperationsController.shared.canUndo
        default: break
        }
        guard menuItem.action == #selector(runCommand(_:)) else { return true }
        guard let id = menuItem.representedObject as? String, let command = Commands.command(id: id) else {
            return false
        }
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
    var pathBarForHooks: NSView { content.pathBar }

    func setSidebarWidthForHooks(_ width: CGFloat) {
        splitController.splitView.setPosition(width, ofDividerAt: 0)
        splitController.splitView.layoutSubtreeIfNeeded()
        let frames = splitController.splitView.arrangedSubviews.map { NSStringFromRect($0.frame) }.joined(
            separator: " | ")
        Self.logger.notice(
            "Sidebar width asked \(width), now \(self.sidebarItem.viewController.view.frame.width), split \(frames, privacy: .public)"
        )
    }

    func logPanesForHooks() {
        if let window {
            Self.logger.notice(
                "Window content layout \(NSStringFromRect(window.contentLayoutRect), privacy: .public), frame \(NSStringFromRect(window.frame), privacy: .public), accessories \(window.titlebarAccessoryViewControllers.count), tab bar \(window.tabGroup?.isTabBarVisible ?? false)"
            )
            for tab in workspace.allContents {
                let bar = tab.pathBar
                Self.logger.notice(
                    "Path bar \(NSStringFromRect(bar.convert(bar.bounds, to: nil)), privacy: .public) hidden \(bar.isHidden) safe top \(tab.view.safeAreaInsets.top)"
                )
            }
        }
        for (index, pane) in workspace.panes.enumerated() {
            Self.logger.notice(
                "Pane \(index)\(index == self.workspace.activePaneIndex ? " (focused)" : ""): tabs \(pane.strip.titles.joined(separator: " | "), privacy: .public), active \(pane.activeIndex), strip \(pane.showsTabStrip), frame \(NSStringFromRect(pane.view.frame), privacy: .public)"
            )
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
    func togglePreview() {
        content.isPreviewVisible.toggle()
        updateToggleButtons()
    }

    func togglePathBar() { content.isPathBarVisible.toggle() }
    func toggleStatusBar() { content.isStatusBarVisible.toggle() }
    func toggleSidebar() { sidebarItem.animator().isCollapsed.toggle() }

    func beginTypingPath() {
        // Split view has no path bar: type the path in the command palette.
        if workspace.isSplit {
            if palette == nil { palette = CommandPalette(controller: self) }
            palette?.show(prefill: model.location.folderURL.map { PathBar.displayPath($0) + "/" } ?? "~/")
            return
        }
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
                .first(where: {
                    $0.volumeURL?.standardizedFileURL == url.standardizedFileURL && $0.canEject && $0.isEnabled
                })
            {
                return item
            }
        }
        return nil
    }

    func ejectSelectedVolume() {
        guard let item = volumeToEject else { return }
        SidebarStore.shared.eject(item, presentingIn: window)
    }

}
