import AppKit
import PandoraEngine
import UniformTypeIdentifiers

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
    var contextMenu: NSMenu? {
        didSet { outlineView.menu = contextMenu }
    }

    private let scrollView = NSScrollView()
    private let outlineView = FileOutlineView()
    private var roots: [FileNode] = []
    private var nodesByURL: [URL: FileNode] = [:]
    private var tagCache: [URL: [String]] = [:]
    private var tagLoads: Set<URL> = []
    private let headerView = NSTableHeaderView()

    enum Column: String, CaseIterable {
        case name, modified, created, added, size, kind, tags

        var title: String {
            switch self {
            case .name: "Name"
            case .modified: "Date Modified"
            case .created: "Date Created"
            case .added: "Date Added"
            case .size: "Size"
            case .kind: "Kind"
            case .tags: "Tags"
            }
        }

        var sortKey: FileSort.Key? {
            switch self {
            case .name: .name
            case .modified: .modified
            case .created: .created
            case .added: .added
            case .size: .size
            case .kind: .kind
            case .tags: nil
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 220
            case .modified, .created, .added: 150
            case .size: 70
            case .kind: 130
            case .tags: 120
            }
        }

        var hiddenByDefault: Bool { self == .created || self == .added || self == .tags }
        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
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
        NotificationCenter.default.addObserver(forName: IconCache.didLoad, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadVisibleNames() }
        }
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
        if change.contains(.viewMode) { applyViewMode() }
        if change.contains(.sort) { applySortIndicator() }
        if change.contains(.items) { reloadItems() }
    }

    private func applyViewMode() {
        let selected = selectedURLs()
        defer { select(selected, scroll: true) }
        let details = model.viewMode == .details
        for column in Column.allCases where column != .name {
            let tableColumn = outlineView.tableColumn(withIdentifier: column.identifier)
            if details {
                tableColumn?.isHidden = UserDefaults.standard.bool(forKey: hiddenKey(column))
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
        outlineView.reloadData()
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
        guard rows.length > 0, let column = outlineView.tableColumns.firstIndex(where: { $0.identifier == Column.name.identifier }) else { return }
        outlineView.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<rows.location + rows.length), columnIndexes: [column])
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
            if let node = outlineView.item(atRow: row) as? FileNode, wanted.contains(node.item.url.standardizedFileURL) {
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
        }
    }

    func openSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        onOpen?(items)
    }

    // MARK: - Header menu (show or hide columns)

    private func hiddenKey(_ column: Column) -> String { "FileListColumnHidden.\(column.rawValue)" }

    private func makeHeaderMenu() -> NSMenu {
        let menu = NSMenu()
        for column in Column.allCases where column != .name {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            menu.addItem(item)
        }
        menu.delegate = self
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = Column(rawValue: raw),
              let tableColumn = outlineView.tableColumn(withIdentifier: column.identifier) else { return }
        tableColumn.isHidden.toggle()
        UserDefaults.standard.set(tableColumn.isHidden, forKey: hiddenKey(column))
        outlineView.reloadData()
    }

    // MARK: - Tags, loaded only for rows on screen

    private func tags(for item: FileItem) -> [String]? {
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
            if row >= 0, let column = self.outlineView.tableColumns.firstIndex(where: { $0.identifier == Column.tags.identifier }) {
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

extension FileListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let raw = item.representedObject as? String, let column = Column(rawValue: raw) else { continue }
            item.state = outlineView.tableColumn(withIdentifier: column.identifier)?.isHidden == false ? .on : .off
        }
    }
}

// MARK: - Data source and delegate

extension FileListViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return roots.count }
        if node.children == nil { loadChildren(of: node) }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return roots[index] }
        return node.children?[index] ?? FileNode(item: node.item)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard model.viewMode == .details, let node = item as? FileNode else { return false }
        return node.item.isBrowsableFolder && !node.item.isSymbolicLink
    }

    private func loadChildren(of node: FileNode) {
        guard !node.isLoadingChildren else { return }
        node.isLoadingChildren = true
        let engine = model.engine
        let url = node.item.url
        let sort = model.sort
        let showHidden = AppSettings.shared.showHiddenFiles
        Task { [weak self] in
            let listed = (try? await engine.contentsOfDirectory(at: url)) ?? []
            let sorted = await Task.detached { sort.sorted(showHidden ? listed : listed.filter { !$0.isHidden }) }.value
            node.children = sorted.map(FileNode.init)
            node.isLoadingChildren = false
            self?.outlineView.reloadItem(node, reloadChildren: true)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode, model.engine.pathGuard.permits(node.item.url) else { return nil }
        return node.item.url as NSURL
    }

    /// The folder a drop lands in: the folder row under the pointer, or the folder on screen.
    private func dropFolder(for item: Any?) -> URL? {
        if let node = item as? FileNode, node.item.isBrowsableFolder, !node.item.isSymbolicLink { return node.item.url }
        return model.location.folderURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard model.engine.pathGuard.allowsWrites else { return [] }
        let target = (item as? FileNode).flatMap { $0.item.isBrowsableFolder ? $0 : nil }
        if target == nil { outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex) }
        else { outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex) }
        guard let folder = dropFolder(for: target) else { return [] }
        return FileViewKeys.dropOperation(info, into: folder)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let folder = dropFolder(for: item) else { return false }
        let urls = FileViewKeys.droppedURLs(info)
        let operation = FileViewKeys.dropOperation(info, into: folder)
        guard !urls.isEmpty, !operation.isEmpty else { return false }
        onDrop?(urls, folder, operation == .copy)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key,
              let sortKey = FileSort.Key(rawValue: key) else { return }
        for node in nodesByURL.values { node.children = nil }
        model.sort = FileSort(key: sortKey, ascending: descriptor.ascending)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        PaletteRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode, let tableColumn,
              let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let file = node.item
        switch column {
        case .name:
            let cell = outlineView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? FileNameCell ?? FileNameCell()
            cell.identifier = tableColumn.identifier
            cell.configure(with: file)
            return cell
        case .tags:
            let cell = textCell(outlineView, tableColumn.identifier)
            cell.textField?.attributedStringValue = Self.tagText(tags(for: file) ?? [])
            return cell
        default:
            let cell = textCell(outlineView, tableColumn.identifier)
            cell.textField?.stringValue = Self.text(for: column, of: file)
            cell.textField?.alignment = column == .size ? .right : .left
            return cell
        }
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard tableColumn?.identifier == Column.name.identifier else { return nil }
        return (item as? FileNode)?.item.name
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    private func textCell(_ outlineView: NSOutlineView, _ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView { return cell }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.textColor = Palette.secondaryText
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    static func text(for column: Column, of item: FileItem) -> String {
        switch column {
        case .name: item.name
        case .modified: DateText.format(item.modified)
        case .created: DateText.format(item.created)
        case .added: DateText.format(item.added)
        case .size: item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "--"
        case .kind: item.kind
        case .tags: ""
        }
    }

    static func tagText(_ tags: [String]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, tag) in tags.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "  ")) }
            text.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: Palette.tagColor(tag) ?? Palette.secondaryText]))
            text.append(NSAttributedString(string: tag, attributes: [.foregroundColor: Palette.secondaryText]))
        }
        return text
    }
}

// MARK: - Cells and rows

/// Icon plus name. Symlinks and aliases get Finder's small arrow badge.
@MainActor
final class FileNameCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badge = NSImageView()

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        badge.image = NSImage(systemSymbolName: "arrow.up.forward.square.fill", accessibilityDescription: "Link")
        badge.symbolConfiguration = .init(pointSize: 8, weight: .bold)
        badge.contentTintColor = Palette.primaryText
        name.lineBreakMode = .byTruncatingMiddle
        name.textColor = Palette.primaryText
        for view in [icon, name, badge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            badge.leadingAnchor.constraint(equalTo: icon.leadingAnchor, constant: -1),
            badge.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 1),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: FileItem) {
        name.stringValue = item.name
        name.alphaValue = item.isHidden ? 0.55 : 1
        icon.alphaValue = item.isHidden ? 0.55 : 1
        icon.image = IconCache.shared.icon(for: item)
        badge.isHidden = !(item.isSymbolicLink || item.isAlias)
    }
}

/// Selection drawn in Pandora's selection colour, with the text staying dark
/// (light in dark mode) rather than turning white.
@MainActor
final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        // The table marks rows emphasized while it has focus in the key window.
        (isEmphasized ? Palette.selection : Palette.separator).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0.5), xRadius: 4, yRadius: 4).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Outline view with Finder's open and Quick Look keys.
@MainActor
final class FileOutlineView: NSOutlineView {
    var onOpenSelection: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onRename: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch FileViewKeys.action(for: event) {
        case .open?: onOpenSelection?()
        case .quickLook?: onQuickLook?()
        case .rename?: onRename?()
        case nil: super.keyDown(with: event)
        }
    }
}

/// Icons by type, cached, so scrolling never asks the disk for an icon.
/// Apps and other packages get their own icon, loaded once in the background.
@MainActor
final class IconCache {
    static let shared = IconCache()

    private var byType: [String: NSImage] = [:]
    private var byPath: [String: NSImage] = [:]
    private var loading: Set<String> = []

    func icon(for item: FileItem) -> NSImage {
        if item.isPackage {
            if let icon = byPath[item.url.path] { return icon }
            loadIcon(for: item.url.path)
        }
        let key: String
        let type: UTType
        if item.isBrowsableFolder || (item.isSymbolicLink && item.kind == "Folder") {
            key = "public.folder"
            type = .folder
        } else if item.isSymbolicLink {
            key = "symlink:" + item.url.pathExtension.lowercased()
            type = UTType(filenameExtension: item.url.pathExtension) ?? .data
        } else {
            key = (item.isPackage ? "package:" : "") + item.url.pathExtension.lowercased()
            type = UTType(filenameExtension: item.url.pathExtension, conformingTo: item.isPackage ? .package : .data) ?? .data
        }
        if let icon = byType[key] { return icon }
        let icon = NSWorkspace.shared.icon(for: type)
        byType[key] = icon
        return icon
    }

    private func loadIcon(for path: String) {
        guard !loading.contains(path) else { return }
        loading.insert(path)
        Task {
            let icon = await Task.detached(priority: .utility) { LoadedIcon(image: NSWorkspace.shared.icon(forFile: path)) }.value
            byPath[path] = icon.image
            loading.remove(path)
            NotificationCenter.default.post(name: Self.didLoad, object: path)
        }
    }

    static let didLoad = Notification.Name("PandoraIconDidLoad")
}

/// Carries an icon from the background task that loaded it. The image is not
/// touched again off the main thread.
private struct LoadedIcon: @unchecked Sendable {
    let image: NSImage
}

/// Dates the way Finder shows them: "Today at 10:31", "Yesterday at 09:12",
/// otherwise the date and time.
enum DateText {
    static func format(_ date: Date?) -> String {
        guard let date else { return "--" }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today at \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
