import AppKit
import ScopeEngine

/// The column view: NSBrowser, starting at the tab's folder, with one column
/// per level. Folders' contents load in the background; a column appears
/// empty for a moment and fills in when its listing arrives.
@MainActor
final class ColumnViewController: NSViewController, FileBrowsingView {
    let model: BrowserModel
    var onOpen: (([FileItem]) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onDrop: (([URL], URL, Bool) -> Void)?
    var onRename: (() -> Void)?
    var onShortcut: ((FileViewKeys.Action) -> Void)?
    var contextMenu: NSMenu? {
        didSet { browser.menu = contextMenu }
    }

    func prepareForContextMenu() {}

    private let browser = FileBrowser()
    private let root = ColumnNode(item: nil)

    init(model: BrowserModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        browser.delegate = self
        browser.focusRingType = .none
        browser.target = self
        browser.action = #selector(selectionChanged)
        browser.doubleAction = #selector(openClicked)
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.hasHorizontalScroller = true
        browser.separatesColumns = true
        browser.isTitled = false
        browser.columnResizingType = .userColumnResizing
        browser.minColumnWidth = 180
        browser.setDefaultColumnWidth(220)
        browser.rowHeight = 22
        browser.backgroundColor = Palette.windowBackground
        browser.autohidesScroller = true
        browser.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        view = browser
        reloadItems()
    }

    // MARK: - FileBrowsingView

    func modelDidChange(_ change: BrowserModel.Change) {
        if change.contains(.location) { root.children = nil }
        if !change.isDisjoint(with: .anyItems) { reloadItems() }
        if !change.isDisjoint(with: [.anyItems, .sort]) {
            root.refreshNestedSettings(sort: model.sort, showHidden: AppSettings.shared.showHiddenFiles)
        }
    }

    func close() { root.children = nil }

    var selectedItems: [FileItem] {
        guard let paths = browser.selectionIndexPaths as [IndexPath]? else { return [] }
        let deepest = paths.map(\.count).max() ?? 0
        return paths.filter { $0.count == deepest }.compactMap { (browser.item(at: $0) as? ColumnNode)?.item }
    }

    @discardableResult
    func select(_ urls: [URL], scroll: Bool) -> Bool {
        let wanted = Set(urls.map(\.standardizedFileURL))
        func paths(in nodes: [ColumnNode], prefix: [Int]) -> [IndexPath] {
            nodes.enumerated().flatMap { index, node -> [IndexPath] in
                let path = prefix + [index]
                let selected = node.item.map { wanted.contains($0.url.standardizedFileURL) } ?? false
                return (selected ? [IndexPath(indexes: path)] : []) + paths(in: node.children ?? [], prefix: path)
            }
        }
        let found = paths(in: root.children ?? [], prefix: [])
        guard !found.isEmpty else { return false }
        let depth = found.map(\.count).max()
        browser.selectionIndexPaths = found.filter { $0.count == depth }
        selectionChanged()
        return true
    }

    func focus() {
        view.window?.makeFirstResponder(browser)
    }

    // MARK: - Content

    private func reloadItems() {
        let selected = selectedItems.map(\.url)
        root.children = ColumnNode.updating(model.items, from: root.children ?? [])
        browser.loadColumnZero()
        if !model.pendingSelection.isEmpty {
            if select(model.pendingSelection, scroll: true) { model.pendingSelection = [] }
        } else if !selected.isEmpty {
            if !select(selected, scroll: false) { browser.selectionIndexPaths = [] }
        }
    }

    private func loadChildren(of node: ColumnNode) {
        guard node.childrenListing == nil, let item = node.item else { return }
        node.isLoadingChildren = true
        node.childrenListing = NestedFolderListing(url: item.url, model: model) { [weak self, weak node] sorted in
            guard let self, let node else { return }
            let selected = Set(self.selectedItems.map(\.url))
            node.children = ColumnNode.updating(sorted, from: node.children ?? [])
            node.isLoadingChildren = false
            self.model.metadataDidChange()
            self.reloadColumn(showing: node, selecting: selected)
            self.onSelectionChange?()
        }
    }

    /// Reloads the column that lists `node`'s children, if it is on screen.
    private func reloadColumn(showing node: ColumnNode, selecting selected: Set<URL>) {
        for column in 0...max(0, browser.lastColumn) {
            if (browser.parentForItems(inColumn: column) as? ColumnNode) === node {
                browser.reloadColumn(column)
                if !select(Array(selected), scroll: false) { browser.selectionIndexPaths = [] }
                return
            }
        }
    }

    @objc private func selectionChanged() {
        onSelectionChange?()
        Task { [weak self] in
            await Task.yield()
            self?.releaseHiddenColumns()
        }
    }

    private func releaseHiddenColumns() {
        let visible = Set(
            (0...max(0, browser.lastColumn)).compactMap {
                (browser.parentForItems(inColumn: $0) as? ColumnNode).map(ObjectIdentifier.init)
            })
        func prune(_ node: ColumnNode) {
            guard node === root || visible.contains(ObjectIdentifier(node)) else {
                node.childrenListing = nil
                node.children = nil
                node.isLoadingChildren = false
                return
            }
            node.children?.forEach(prune)
        }
        prune(root)
    }

    @objc private func openClicked() {
        let items = selectedItems
        if !items.isEmpty { onOpen?(items) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if FileViewKeys.isArrowWithoutSelection(event, hasSelection: !selectedItems.isEmpty),
            let first = model.items.first
        {
            select([first.url], scroll: true)
            return true
        }
        switch FileViewKeys.action(for: event) {
        case .open?:
            openClicked()
            return true
        case .quickLook?:
            onQuickLook?()
            return true
        case .rename?:
            onRename?()
            return true
        case let other?:
            onShortcut?(other)
            return true
        case nil:
            return false
        }
    }
}

/// A node in the column view. The root has no item.
@MainActor
final class ColumnNode {
    var item: FileItem?
    var children: [ColumnNode]?
    var isLoadingChildren = false
    var childrenListing: NestedFolderListing?

    func refreshNestedSettings(sort: FileSort, showHidden: Bool) {
        childrenListing?.update(sort: sort, showHidden: showHidden)
        children?.forEach { $0.refreshNestedSettings(sort: sort, showHidden: showHidden) }
    }

    init(item: FileItem?) {
        self.item = item
    }

    static func updating(_ items: [FileItem], from nodes: [ColumnNode]) -> [ColumnNode] {
        let old = Dictionary(
            nodes.compactMap { node in node.item.map { ($0.url, node) } },
            uniquingKeysWith: { a, _ in a })
        return items.map { item in
            guard let kept = old[item.url] else { return ColumnNode(item: item) }
            let keepsChildren =
                kept.item?.isBrowsableFolder == true && kept.item?.isSymbolicLink == false
                && item.isBrowsableFolder && !item.isSymbolicLink
            kept.item = item
            if !keepsChildren {
                kept.childrenListing = nil
                kept.children = nil
                kept.isLoadingChildren = false
            }
            return kept
        }
    }
}

extension ColumnViewController: NSBrowserDelegate {
    func rootItem(for browser: NSBrowser) -> Any? {
        root
    }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? ColumnNode else { return 0 }
        if node.children == nil, node !== root { loadChildren(of: node) }
        return node.children?.count ?? 0
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? ColumnNode, let children = node.children, children.indices.contains(index) else {
            return ColumnNode(item: nil)
        }
        return children[index]
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        guard let file = (item as? ColumnNode)?.item else { return true }
        return !(file.isBrowsableFolder && !file.isSymbolicLink)
    }

    /// Each row is the item's icon and name. NSBrowser's item-based mode
    /// doesn't ask for cell images, so the icon rides along as a text attachment.
    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        guard let file = (item as? ColumnNode)?.item else { return "" }
        let icon = (IconCache.shared.icon(for: file).copy() as? NSImage) ?? NSImage()
        icon.size = NSSize(width: 16, height: 16)
        let attachment = NSTextAttachment()
        attachment.image = icon
        attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(
            NSAttributedString(
                string: "  " + file.name,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: file.isHidden ? Palette.secondaryText : Palette.primaryText,
                ]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        return text
    }

    func browser(_ browser: NSBrowser, shouldEditItem item: Any?) -> Bool {
        false
    }
}

/// NSBrowser that hands Finder's open and Quick Look keys to its controller.
@MainActor
final class FileBrowser: NSBrowser {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}
