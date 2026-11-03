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
    var childrenListing: NestedFolderListing?

    func refreshNestedSettings(sort: FileSort, showHidden: Bool) {
        childrenListing?.update(sort: sort, showHidden: showHidden)
        children?.forEach { $0.refreshNestedSettings(sort: sort, showHidden: showHidden) }
    }

    init(item: FileItem) {
        self.item = item
    }

    func update(_ item: FileItem) {
        let keepsChildren =
            self.item.isBrowsableFolder && !self.item.isSymbolicLink
            && item.isBrowsableFolder && !item.isSymbolicLink
        self.item = item
        if !keepsChildren {
            children = nil
            childrenListing = nil
            isLoadingChildren = false
        }
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
    private let tagCache: FileTagCache
    /// Cached tags that may be out of date: still shown, but read again.
    var staleTags: Set<URL> { tagCache.staleURLs }
    private let headerView = NSTableHeaderView()
    private var observers: [NSObjectProtocol] = []

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    init(model: BrowserModel, tagCache: FileTagCache? = nil) {
        self.model = model
        self.tagCache = tagCache ?? FileTagCache(engine: model.engine)
        super.init(nibName: nil, bundle: nil)
        self.tagCache.onChange = { [weak self] url in self?.tagsChanged(at: url) }
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

    func close() {
        tagCache.close()
        roots = []
        nodesByURL = [:]
    }

    func modelDidChange(_ change: BrowserModel.Change) {
        if !change.isDisjoint(with: [.anyItems, .location, .metadata]) {
            tagCache.invalidate(clear: change.contains(.location))
        }
        if change.contains(.location) {
            nodesByURL = [:]
        }
        if change.contains(.viewMode) || change.contains(.location) { applyViewMode() }
        if change.contains(.sort) { applySortIndicator() }
        if change.contains(.items) {
            reloadItems()
        } else if change.contains(.itemsUpdated) {
            applyRowChanges()
        }
        if change.contains(.metadata) {
            // Read the tags on screen again; only rows whose tags changed are
            // redrawn, so a rename being typed isn't interrupted.
            let visible = outlineView.rows(in: outlineView.visibleRect)
            for row in visible.location..<NSMaxRange(visible) {
                if let node = outlineView.item(atRow: row) as? FileNode { _ = tags(for: node.item) }
            }
        }
        if !change.isDisjoint(with: [.anyItems, .sort]) {
            roots.forEach { $0.refreshNestedSettings(sort: model.sort, showHidden: AppSettings.shared.showHiddenFiles) }
        }
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
                node.update(item)
            }
            reused[item.url] = node
            return node
        }
        nodesByURL = reused
        outlineView.reloadData()

        // A pending selection is kept until the item shows up: the first
        // update after navigating is empty.
        if !selectPending() { select(selected, scroll: false) }
    }

    /// Updates only the top-level rows that changed on disk, so expanded
    /// folders keep their children and the selection and scroll stay put.
    /// Anything that doesn't add up falls back to a full reload.
    private func applyRowChanges() {
        let items = model.items
        guard let changes = model.rowChanges, outlineView.numberOfChildren(ofItem: nil) == roots.count,
            let updated = changes.applied(
                to: roots, newCount: items.count, makeRow: { FileNode(item: items[$0]) }),
            zip(updated, items).allSatisfy({ $0.item.url == $1.url })
        else {
            reloadItems()
            return
        }
        var redrawn: [FileNode] = []
        for index in changes.reloaded where updated[index].item != items[index] {
            let node = updated[index]
            node.update(items[index])
            redrawn.append(node)
        }
        roots = updated
        nodesByURL = Dictionary(updated.map { ($0.item.url, $0) }, uniquingKeysWith: { _, last in last })
        outlineView.beginUpdates()
        outlineView.removeItems(at: changes.removed, inParent: nil, withAnimation: [])
        outlineView.insertItems(at: changes.inserted, inParent: nil, withAnimation: [])
        outlineView.endUpdates()
        for node in redrawn { outlineView.reloadItem(node, reloadChildren: true) }
        selectPending()
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
        let rows = rows(for: urls)
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        if scroll, let first = rows.first { outlineView.scrollRowToVisible(first) }
        return !rows.isEmpty
    }

    private func rows(for urls: [URL]) -> IndexSet {
        let wanted = Set(urls.map(\.standardizedFileURL))
        var rows = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? FileNode, wanted.contains(node.item.url.standardizedFileURL)
            {
                rows.insert(row)
            }
        }
        return rows
    }

    /// Selects the items the model is waiting to select, once they're here.
    /// Until then the user's selection stays: a pending item that never
    /// shows up (Back to a folder that doesn't hold the one left) must not
    /// clear it on every change on disk.
    @discardableResult
    private func selectPending() -> Bool {
        guard !model.pendingSelection.isEmpty, !rows(for: model.pendingSelection).isEmpty else { return false }
        select(model.pendingSelection, scroll: true)
        model.pendingSelection = []
        return true
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
        tagCache.tags(for: item.url)
    }

    private func tagsChanged(at url: URL) {
        guard let node = nodesByURL[url] ?? findNode(url) else { return }
        let row = outlineView.row(forItem: node)
        if row >= 0 { outlineView.reloadData(forRowIndexes: [row], columnIndexes: tagColumns) }
    }

    /// The columns that show tags: the name (as dots) and the Tags column.
    private var tagColumns: IndexSet {
        IndexSet(
            outlineView.tableColumns.indices.filter {
                let id = outlineView.tableColumns[$0].identifier
                return id == Column.name.identifier || id == Column.tags.identifier
            })
    }

    private func findNode(_ url: URL) -> FileNode? {
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? FileNode, node.item.url == url { return node }
        }
        return nil
    }
}
