import AppKit

/// Split view and the tabs inside each pane: turning split on and off,
/// opening places on the other side, and moving tabs between panes.
extension BrowserWindowController {
    var isSplit: Bool { workspace.isSplit }

    /// Shows a second pane beside the first, at the same folder, or closes it.
    /// The preview pane hides while split is on.
    func toggleSplit() {
        if workspace.isSplit {
            if let removed = workspace.removeRightPane() {
                if let item = splitController.splitViewItems.first(where: { $0.viewController === removed }) {
                    splitController.removeSplitViewItem(item)
                }
                if let index = contentItem.topAlignedAccessoryViewControllers.firstIndex(where: {
                    $0 === workspace.panes[0].header
                }) {
                    contentItem.removeTopAlignedAccessoryViewController(at: index)
                }
                for tab in removed.tabs {
                    tab.close()
                    tab.model.close()
                }
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
            item.minimumThickness = 280
            // Adding an item makes the split view grow the window to fit it;
            // keep the window where it was and share its width instead.
            let frame = window?.frame
            splitController.addSplitViewItem(item)
            if let frame { window?.setFrame(frame, display: true) }
            contentItem.addTopAlignedAccessoryViewController(workspace.panes[0].header)
            item.addTopAlignedAccessoryViewController(pane.header)
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

    /// The folder "Open in Split View" would open: a single selected folder.
    var folderForSplit: URL? {
        guard selectedItems.count == 1, let item = selectedItems.first, item.isBrowsableFolder else { return nil }
        return item.url
    }

    /// Opens the selected folder on the other side: turns split view on if
    /// needed, otherwise opens it in a new tab on the other side.
    func openInSplit() {
        guard let folder = folderForSplit else { return }
        openInSplit(.folder(folder))
    }

    /// Shows `location` on the other side (from a folder or a sidebar item).
    func openInSplit(_ location: Location) {
        if !workspace.isSplit {
            toggleSplit()
            model.navigate(to: location)
        } else {
            let other = workspace.activePaneIndex == 0 ? 1 : 0
            let pane = workspace.panes[other]
            let tab = makeTab(at: location)
            pane.addTab(tab)
            focusPane(other)
        }
    }

    func makeTab(at location: Location) -> BrowserViewController {
        let tab = BrowserViewController(
            model: BrowserModel(engine: BuildIdentity.current.makeEngine(), location: location))
        wire(tab)
        // A real starting size, so its layout doesn't fight a zero-sized frame.
        tab.view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        if workspace.isSplit { tab.isPreviewVisible = false }
        return tab
    }

    func addTab(to pane: PaneController) {
        let tab = makeTab(at: pane.activeTab.model.location)
        if workspace.isSplit { tab.isPreviewVisible = false }
        pane.addTab(tab)
    }

    func tabAction(_ action: PaneTabStrip.Action, in pane: PaneController, at index: Int) {
        guard pane.tabs.indices.contains(index) else { return }
        let tab = pane.tabs[index]
        switch action {
        case .duplicate:
            pane.addTab(makeTab(at: tab.model.location))
        case .closeOthers:
            for other in pane.tabs.indices.reversed() where other != index { closeTab(in: pane, at: other) }
        case .moveToOtherSide:
            guard let target = workspace.panes.first(where: { $0 !== pane }) else { return }
            target.addTab(makeTab(at: tab.model.location))
            if pane.tabs.count > 1 { closeTab(in: pane, at: index) }
        }
    }

    /// Opens a folder or sidebar place in a new tab: on the focused side in
    /// split view, otherwise as a new window tab.
    func openInNewTab(_ location: Location) {
        if workspace.isSplit {
            workspace.activePane.addTab(makeTab(at: location))
            return
        }
        guard let window, let app = NSApp.delegate as? AppDelegate else { return }
        let tab = app.makeBrowser(location: location)
        if let tabWindow = tab.window {
            window.addTabbedWindow(tabWindow, ordered: .above)
            tabWindow.makeKeyAndOrderFront(nil)
        }
    }

    func openSelectionInNewTab() {
        guard let folder = folderForSplit else { return }
        openInNewTab(.folder(folder))
    }

    func closeTab(in pane: PaneController, at index: Int) {
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
}
