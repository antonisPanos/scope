import AppKit
import SwiftUI

/// The window toolbar: back and forward, view modes, activity, split view,
/// details panel, command palette and search.
extension BrowserWindowController: NSToolbarDelegate {
    private static let navigationItem = NSToolbarItem.Identifier("navigation")
    private static let viewModeItem = NSToolbarItem.Identifier("viewMode")
    private static let paletteItem = NSToolbarItem.Identifier("palette")
    private static let activityItem = NSToolbarItem.Identifier("activity")
    private static let searchItem = NSToolbarItem.Identifier("search")
    private static let previewItem = NSToolbarItem.Identifier("preview")
    private static let splitItem = NSToolbarItem.Identifier("split")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, .sidebarTrackingSeparator, Self.navigationItem, .flexibleSpace, Self.activityItem,
            Self.viewModeItem,
            Self.splitItem, Self.previewItem, Self.paletteItem, Self.searchItem,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.navigationItem:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: [
                    NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                    NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!,
                ],
                selectionMode: .momentary, labels: ["Back", "Forward"], target: self,
                action: #selector(navigationClicked(_:)))
            group.label = "Back/Forward"
            group.subitems[0].toolTip = "Back (⌘[)"
            group.subitems[1].toolTip = "Forward (⌘])"
            group.isNavigational = true
            navigationGroup = group
            updateToolbar()
            return group
        case Self.viewModeItem:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: ViewMode.allCases.map {
                    NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: $0.title)!
                },
                selectionMode: .selectOne, labels: ViewMode.allCases.map(\.title), target: self,
                action: #selector(viewModeClicked(_:)))
            group.label = "View"
            for (index, mode) in ViewMode.allCases.enumerated() {
                group.subitems[index].toolTip = "\(mode.title) (⌘\(mode.shortcut))"
            }
            group.controlRepresentation = .expanded
            viewModeGroup = group
            updateToolbar()
            return group
        case Self.activityItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Activity"
            item.toolTip = "Activity (⌥⌘A)"
            item.view = NSHostingView(
                rootView: ActivityRing(controller: OperationsController.shared) { [weak self] in
                    guard let self else { return }
                    self.showActivity(!self.isActivityVisible)
                })
            return item
        case Self.splitItem:
            // One-button groups, so the button shows when its pane is on,
            // like the view buttons do.
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: [NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Split View")!],
                selectionMode: .selectAny, labels: ["Split View"], target: self, action: #selector(splitClicked))
            group.label = "Split View"
            group.subitems[0].toolTip = "Split View (⇧⌘S)"
            splitGroup = group
            updateToggleButtons()
            return group
        case Self.previewItem:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: [NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Details Panel")!],
                selectionMode: .selectAny, labels: ["Details"], target: self, action: #selector(previewClicked))
            group.label = "Details"
            group.subitems[0].toolTip = "Show or Hide the Details Panel (⇧⌘P)"
            previewGroup = group
            updateToggleButtons()
            return group
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

    @objc private func splitClicked() {
        toggleSplit()
        updateToggleButtons()
    }

    @objc private func previewClicked() {
        togglePreview()
        updateToggleButtons()
    }

    /// Shows the split view and details panel buttons as on or off.
    func updateToggleButtons() {
        splitGroup?.setSelected(isSplit, at: 0)
        previewGroup?.setSelected(isPreviewVisible, at: 0)
        // The details panel can't be shown in split view.
        previewGroup?.isEnabled = !isSplit
    }

    @objc private func paletteClicked() {
        showCommandPalette()
    }

    func updateToolbar() {
        updateToggleButtons()
        navigationGroup?.subitems[0].isEnabled = model.canGoBack
        navigationGroup?.subitems[1].isEnabled = model.canGoForward
        viewModeGroup?.selectedIndex = ViewMode.allCases.firstIndex(of: model.viewMode) ?? 0
    }
}
