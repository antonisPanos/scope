import AppKit
import PandoraEngine

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
        if change.contains(.items) { reloadItems() }
    }

    var selectedItems: [FileItem] {
        guard let paths = browser.selectionIndexPaths as [IndexPath]? else { return [] }
        let deepest = paths.map(\.count).max() ?? 0
        return paths.filter { $0.count == deepest }.compactMap { (browser.item(at: $0) as? ColumnNode)?.item }
    }

    @discardableResult
    func select(_ urls: [URL], scroll: Bool) -> Bool {
        let wanted = Set(urls.map(\.standardizedFileURL))
        let rows = (root.children ?? []).indices.filter {
            (root.children?[$0].item).map { wanted.contains($0.url.standardizedFileURL) } ?? false
        }
        guard !rows.isEmpty else { return false }
        browser.selectRowIndexes(IndexSet(rows), inColumn: 0)
        onSelectionChange?()
        return true
    }

    func focus() {
        view.window?.makeFirstResponder(browser)
    }

    // MARK: - Content

    private func reloadItems() {
        let selected = selectedItems.map(\.url)
        let fresh = model.items.map { ColumnNode(item: $0) }
        // Keep the deeper columns' nodes for folders that are still there.
        let old = Dictionary((root.children ?? []).compactMap { node in node.item.map { ($0.url, node) } }, uniquingKeysWith: { a, _ in a })
        root.children = fresh.map { node in
            guard let url = node.item?.url, let kept = old[url], kept.item == node.item else { return node }
            return kept
        }
        browser.loadColumnZero()
        if let pending = model.pendingSelection {
            if select([pending], scroll: true) { model.pendingSelection = nil }
        } else if !selected.isEmpty {
            select(selected, scroll: false)
        }
    }

    private func loadChildren(of node: ColumnNode) {
        guard !node.isLoadingChildren, let item = node.item else { return }
        node.isLoadingChildren = true
        let engine = model.engine
        let sort = model.sort
        let showHidden = AppSettings.shared.showHiddenFiles
        Task { [weak self] in
            let listed = (try? await engine.contentsOfDirectory(at: item.url)) ?? []
            let sorted = await Task.detached { sort.sorted(showHidden ? listed : listed.filter { !$0.isHidden }) }.value
            node.children = sorted.map { ColumnNode(item: $0) }
            node.isLoadingChildren = false
            self?.reloadColumn(showing: node)
        }
    }

    /// Reloads the column that lists `node`'s children, if it is on screen.
    private func reloadColumn(showing node: ColumnNode) {
        for column in 0...max(0, browser.lastColumn) {
            if (browser.parentForItems(inColumn: column) as? ColumnNode) === node {
                browser.reloadColumn(column)
                return
            }
        }
    }

    @objc private func selectionChanged() {
        onSelectionChange?()
    }

    @objc private func openClicked() {
        let items = selectedItems
        if !items.isEmpty { onOpen?(items) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
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
        case nil:
            return false
        }
    }
}

/// A node in the column view. The root has no item.
@MainActor
final class ColumnNode {
    let item: FileItem?
    var children: [ColumnNode]?
    var isLoadingChildren = false

    init(item: FileItem?) {
        self.item = item
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

    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        (item as? ColumnNode)?.item?.name ?? ""
    }

    func browser(_ sender: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? NSBrowserCell,
              let file = (sender.item(atRow: row, inColumn: column) as? ColumnNode)?.item else { return }
        let icon = IconCache.shared.icon(for: file).copy() as? NSImage
        icon?.size = NSSize(width: 16, height: 16)
        cell.image = icon
        cell.font = .systemFont(ofSize: NSFont.systemFontSize)
        cell.lineBreakMode = .byTruncatingMiddle
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
