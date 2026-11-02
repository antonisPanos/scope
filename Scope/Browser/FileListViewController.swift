import AppKit
import ScopeEngine

/// One row of the file list. Rows are reused across reloads by URL, so the
/// outline view keeps folders expanded and the selection stays put.
@MainActor
final class FileNode {
    var item: FileItem
    /// Children of an expanded folder in the details view; nil until loaded.
    var children: [FileNode]?
    var isLoadingChildren = false

    init(item: FileItem) {
        self.item = item
    }
}

/// The list and details views: an NSOutlineView fed by the browser model.
/// In the list view only the name column shows and folders don't expand; in
/// the details view folders expand in place, Finder style.
@MainActor
final class FileListViewController: NSViewController, FileBrowsingView {
    let model: BrowserModel
    /// Called when the user opens items (double-click, Cmd+Down, Cmd+O).
    var onOpen: (([FileItem]) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onDrop: (([URL], URL, Bool) -> Void)?
    var onRename: (() -> Void)?
    var onShortcut: ((FileViewKeys.Action) -> Void)?
    var contextMenu: NSMenu? {
        didSet { outlineView.menu = contextMenu }
    }

    private let scrollView = NSScrollView()
    let outlineView = FileOutlineView()
    var roots: [FileNode] = []
    var nodesByURL: [URL: FileNode] = [:]
    private var tagCache: [URL: [String]] = [:]
    private var tagLoads: Set<URL> = []
    private let headerView = NSTableHeaderView()
    private var observers: [NSObjectProtocol] = []

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    init(model: BrowserModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            // Dates and kinds stay readable; the name column absorbs the rest.
            tableColumn.minWidth = column == .name ? 160 : column.width * 0.65
            tableColumn.isHidden = column.hiddenByDefault
            if let key = column.sortKey {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            }
            if column == .size { tableColumn.headerCell.alignment = .right }
            outlineView.addTableColumn(tableColumn)
            if column == .name { outlineView.outlineTableColumn = tableColumn }
        }
        headerView.menu = makeHeaderMenu()
        outlineView.headerView = headerView
        outlineView.style = .fullWidth
        // The selection colour already shows focus; skip the system ring around the list.
        outlineView.focusRingType = .none
        outlineView.rowHeight = 22
        outlineView.intercellSpacing = NSSize(width: 6, height: 0)
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.backgroundColor = Palette.windowBackground
        outlineView.allowsMultipleSelection = true
        outlineView.allowsColumnReordering = true
        outlineView.allowsColumnResizing = true
        // The name column takes up any spare width, as in Finder.
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.autosaveName = "FileListColumns.v3"
        outlineView.autosaveTableColumns = true
        outlineView.autosaveExpandedItems = false
        outlineView.indentationPerLevel = 14
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(openClicked)
        outlineView.onOpenSelection = { [weak self] in self?.openSelection() }
        outlineView.onQuickLook = { [weak self] in self?.onQuickLook?() }
        outlineView.onRename = { [weak self] in self?.onRename?() }
        outlineView.onShortcut = { [weak self] action in self?.onShortcut?(action) }
        outlineView.registerForDraggedTypes(FileViewKeys.dropTypes)
        outlineView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        outlineView.setDraggingSourceOperationMask([.copy, .generic], forLocal: false)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.windowBackground
        view = scrollView
        scrollView.contentView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.fitNameColumn(fill: false) }
            })
        observers.append(
            center.addObserver(forName: IconCache.didLoad, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadVisibleNames() }
            })
        applyViewMode()
        applySortIndicator()
        // When swapped in for another view, the model already has items.
        reloadItems()
    }

    // MARK: - Updates from the model

    func modelDidChange(_ change: BrowserModel.Change) {
        if change.contains(.location) {
            nodesByURL = [:]
            tagCache = [:]
        }
        if change.contains(.viewMode) || change.contains(.location) { applyViewMode() }
        if change.contains(.sort) { applySortIndicator() }
        if change.contains(.items) { reloadItems() }
    }

    private func applyViewMode() {
        let selected = selectedURLs()
        defer { select(selected, scroll: true) }
        let details = model.viewMode == .details
        for column in Column.allCases where column != .name {
            let tableColumn = outlineView.tableColumn(withIdentifier: column.identifier)
            if column == .location {
                // "Where" shows only for search results, in the details view.
                tableColumn?.isHidden = !(details && model.location.isSearch)
                continue
            }
            if details {
                tableColumn?.isHidden =
                    UserDefaults.standard.bool(forKey: hiddenKey(column))
                    || (column.hiddenByDefault && UserDefaults.standard.object(forKey: hiddenKey(column)) == nil)
            } else {
                tableColumn?.isHidden = true
            }
        }
        if !details { outlineView.collapseItem(nil, collapseChildren: true) }
        // The list view has no column headers; removing the header view (not
        // just hiding it) gives its space back to the rows.
        outlineView.headerView = details ? headerView : nil
        scrollView.tile()
        scrollView.hasHorizontalScroller = details
        outlineView.indentationPerLevel = details ? 14 : 0
        outlineView.tile()
        fitNameColumn(fill: true)
        outlineView.reloadData()
    }

    /// Keeps every visible column on screen. The list view widens the name
    /// column to the whole window, and that width is saved, so coming back to
    /// Details could leave it wide enough to push the other columns out of
    /// view. With `fill`, it also grows to take up spare width.
    private func fitNameColumn(fill: Bool) {
        guard let name = outlineView.tableColumn(withIdentifier: Column.name.identifier) else { return }
        let available = scrollView.contentView.bounds.width
        guard available > 0 else { return }
        let others = outlineView.tableColumns.filter { $0 !== name && !$0.isHidden }
        let spacing = outlineView.intercellSpacing.width * CGFloat(others.count + 1)
        let fitted = max(name.minWidth, (available - others.reduce(0) { $0 + $1.width } - spacing).rounded(.down))
        if name.width > fitted || (fill && name.width < fitted) { name.width = fitted }
    }

    private func applySortIndicator() {
        let sort = model.sort
        outlineView.sortDescriptors = [NSSortDescriptor(key: sort.key.rawValue, ascending: sort.ascending)]
    }

    private func reloadItems() {
        let selected = selectedURLs()
        var reused: [URL: FileNode] = [:]
        roots = model.items.map { item in
            let node = nodesByURL[item.url] ?? FileNode(item: item)
            if node.item != item {
                node.item = item
                node.children = nil
            }
            reused[item.url] = node
            return node
        }
        nodesByURL = reused
        outlineView.reloadData()

        if let pending = model.pendingSelection {
            // Kept until the item shows up: the first update after navigating is empty.
            if select([pending], scroll: true) { model.pendingSelection = nil }
        } else {
            select(selected, scroll: false)
        }
    }

    private func reloadVisibleNames() {
        let rows = outlineView.rows(in: outlineView.visibleRect)
        guard rows.length > 0,
            let column = outlineView.tableColumns.firstIndex(where: { $0.identifier == Column.name.identifier })
        else { return }
        outlineView.reloadData(
            forRowIndexes: IndexSet(integersIn: rows.location..<rows.location + rows.length), columnIndexes: [column])
    }

    // MARK: - Selection

    var selectedItems: [FileItem] {
        outlineView.selectedRowIndexes.compactMap { (outlineView.item(atRow: $0) as? FileNode)?.item }
    }

    private func selectedURLs() -> [URL] {
        selectedItems.map(\.url)
    }

    @discardableResult
    func select(_ urls: [URL], scroll: Bool) -> Bool {
        let wanted = Set(urls.map(\.standardizedFileURL))
        var rows = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? FileNode, wanted.contains(node.item.url.standardizedFileURL)
            {
                rows.insert(row)
            }
        }
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        if scroll, let first = rows.first { outlineView.scrollRowToVisible(first) }
        return !rows.isEmpty
    }

    func focus() {
        view.window?.makeFirstResponder(outlineView)
        if outlineView.selectedRow < 0, outlineView.numberOfRows > 0 {
            outlineView.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    @objc private func openClicked() {
        guard outlineView.clickedRow >= 0 else { return }
        openSelection()
    }

    func prepareForContextMenu() {
        let row = outlineView.clickedRow
        if row >= 0, !outlineView.selectedRowIndexes.contains(row) {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        } else if row < 0 {
            // Right-clicking empty space is about the folder itself, as in Finder.
            outlineView.deselectAll(nil)
        }
    }

    func openSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        onOpen?(items)
    }

    // MARK: - Tags, loaded only for rows on screen

    func tags(for item: FileItem) -> [String]? {
        if let cached = tagCache[item.url] { return cached }
        guard !tagLoads.contains(item.url) else { return nil }
        tagLoads.insert(item.url)
        let engine = model.engine
        let url = item.url
        Task { [weak self] in
            let tags = (try? await engine.tags(for: url)) ?? []
            guard let self else { return }
            self.tagLoads.remove(url)
            self.tagCache[url] = tags
            guard let node = self.nodesByURL[url] ?? self.findNode(url) else { return }
            let row = self.outlineView.row(forItem: node)
            if row >= 0,
                let column = self.outlineView.tableColumns.firstIndex(where: { $0.identifier == Column.tags.identifier }
                )
            {
                self.outlineView.reloadData(forRowIndexes: [row], columnIndexes: [column])
            }
        }
        return nil
    }

    private func findNode(_ url: URL) -> FileNode? {
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? FileNode, node.item.url == url { return node }
        }
        return nil
    }
}
