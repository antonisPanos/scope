import AppKit
import ScopeEngine

/// The icon view: a grid of icons or thumbnails that re-flows as the window
/// resizes, sized by the slider, Cmd+Plus and Cmd+Minus, or a pinch. The same
/// controller, in strip mode, is the row of thumbnails under the gallery's
/// large preview.
@MainActor
final class IconGridViewController: NSViewController, FileBrowsingView {
    enum Style { case grid, strip }

    let model: BrowserModel
    let style: Style
    var onOpen: (([FileItem]) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onDrop: (([URL], URL, Bool) -> Void)?
    var onRename: (() -> Void)?
    var onShortcut: ((FileViewKeys.Action) -> Void)?
    var contextMenu: NSMenu? {
        didSet { collectionView.menu = contextMenu }
    }

    private let scrollView = NSScrollView()
    private let collectionView = IconCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private var items: [FileItem] = []
    private var typeSelect = ""
    private var typeSelectTime = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    private static let itemIdentifier = NSUserInterfaceItemIdentifier("IconItem")

    init(model: BrowserModel, style: Style) {
        self.model = model
        self.style = style
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func loadView() {
        layout.scrollDirection = style == .strip ? .horizontal : .vertical
        layout.minimumInteritemSpacing = style == .strip ? 6 : 8
        layout.minimumLineSpacing = style == .strip ? 6 : 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.focusRingType = .none
        collectionView.allowsMultipleSelection = style == .grid
        collectionView.backgroundColors = [Palette.windowBackground]
        collectionView.register(IconItem.self, forItemWithIdentifier: Self.itemIdentifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.onDoubleClick = { [weak self] in self?.openSelection() }
        collectionView.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        collectionView.registerForDraggedTypes(FileViewKeys.dropTypes)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        collectionView.setDraggingSourceOperationMask([.copy, .generic], forLocal: false)
        collectionView.onRightClick = { [weak self] point in self?.selectItem(at: point) }
        collectionView.onMagnify = { [weak self] factor in
            guard self?.style == .grid else { return }
            AppSettings.shared.iconSize *= factor
        }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = style == .grid
        scrollView.hasHorizontalScroller = style == .strip
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = Palette.windowBackground
        view = scrollView

        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: AppSettings.iconSizeDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applySize() }
            })
        observers.append(
            center.addObserver(forName: ThumbnailCache.didLoad, object: nil, queue: .main) { [weak self] note in
                let url = note.object as? URL
                MainActor.assumeIsolated { self?.thumbnailLoaded(url) }
            })
        observers.append(
            center.addObserver(forName: IconCache.didLoad, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisible() }
            })
        applySize()
        reloadItems()
    }

    // MARK: - FileBrowsingView

    func modelDidChange(_ change: BrowserModel.Change) {
        if change.contains(.items) { reloadItems() }
    }

    var selectedItems: [FileItem] {
        collectionView.selectionIndexPaths.sorted().compactMap {
            items.indices.contains($0.item) ? items[$0.item] : nil
        }
    }

    @discardableResult
    func select(_ urls: [URL], scroll: Bool) -> Bool {
        let wanted = Set(urls.map(\.standardizedFileURL))
        let paths = Set(
            items.indices.filter { wanted.contains(items[$0].url.standardizedFileURL) }.map {
                IndexPath(item: $0, section: 0)
            })
        collectionView.selectionIndexPaths = paths
        if scroll, let first = paths.min() {
            collectionView.scrollToItems(
                at: [first], scrollPosition: style == .strip ? .centeredHorizontally : .nearestHorizontalEdge)
        }
        onSelectionChange?()
        return !paths.isEmpty
    }

    func focus() {
        view.window?.makeFirstResponder(collectionView)
        if collectionView.selectionIndexPaths.isEmpty, !items.isEmpty {
            select([items[0].url], scroll: false)
        }
    }

    func prepareForContextMenu() {}

    /// Right-clicking an icon that isn't selected selects it first.
    private func selectItem(at point: NSPoint) {
        guard let path = collectionView.indexPathForItem(at: point) else {
            // Right-clicking empty space is about the folder itself, as in Finder.
            if !collectionView.selectionIndexPaths.isEmpty {
                collectionView.selectionIndexPaths = []
                onSelectionChange?()
            }
            return
        }
        if !collectionView.selectionIndexPaths.contains(path) {
            collectionView.selectionIndexPaths = [path]
            onSelectionChange?()
        }
    }

    // MARK: - Content

    private func reloadItems() {
        let selected = selectedItems.map(\.url)
        items = model.items
        collectionView.reloadData()
        if let pending = model.pendingSelection {
            if select([pending], scroll: true) { model.pendingSelection = nil }
        } else if !selected.isEmpty {
            select(selected, scroll: false)
        }
    }

    var iconSize: CGFloat {
        style == .strip ? 56 : CGFloat(AppSettings.shared.iconSize)
    }

    private func applySize() {
        let size = iconSize
        // Room for two lines of name under the icon in the grid; none in the strip.
        layout.itemSize =
            style == .strip
            ? NSSize(width: size + 12, height: size + 12)
            : NSSize(width: max(size + 24, 84), height: size + 46)
        layout.invalidateLayout()
        refreshVisible()
    }

    private func refreshVisible() {
        for item in collectionView.visibleItems() {
            guard let item = item as? IconItem, let path = collectionView.indexPath(for: item),
                items.indices.contains(path.item)
            else { continue }
            configure(item, with: items[path.item])
        }
    }

    private func thumbnailLoaded(_ url: URL?) {
        guard let url, let index = items.firstIndex(where: { $0.url == url }),
            let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? IconItem
        else { return }
        configure(item, with: items[index])
    }

    private func configure(_ item: IconItem, with file: FileItem) {
        let size = iconSize
        let scale = view.window?.backingScaleFactor ?? 2
        let thumbnail = ThumbnailCache.shared.thumbnail(
            for: file, pointSize: size, scale: scale, pathGuard: model.engine.pathGuard)
        item.show(file, image: thumbnail ?? IconCache.shared.icon(for: file), iconSize: size, showsName: style == .grid)
    }

    // MARK: - Keys

    private func openSelection() {
        let selected = selectedItems
        if !selected.isEmpty { onOpen?(selected) }
    }

    /// Returns true when the key was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        if FileViewKeys.isArrowWithoutSelection(event, hasSelection: !collectionView.selectionIndexPaths.isEmpty),
            let first = items.first
        {
            select([first.url], scroll: true)
            return true
        }
        switch FileViewKeys.action(for: event) {
        case .open?:
            openSelection()
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
            break
        }
        // Type to select, as in Finder: letters typed within a second add up.
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty, let characters = event.characters, !characters.isEmpty,
            characters.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.union(.punctuationCharacters).contains($0)
            })
        else { return false }
        if Date().timeIntervalSince(typeSelectTime) > 1 { typeSelect = "" }
        typeSelect += characters
        typeSelectTime = Date()
        if let match = items.first(where: { $0.name.lowercased().hasPrefix(typeSelect.lowercased()) }) {
            select([match.url], scroll: true)
        }
        return true
    }
}

extension IconGridViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemIdentifier, for: indexPath) as! IconItem
        configure(item, with: items[indexPath.item])
        return item
    }

    /// Without this a collection view never starts a drag.
    func collectionView(
        _ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent
    ) -> Bool {
        true
    }

    func collectionView(
        _ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath
    ) -> NSPasteboardWriting? {
        guard items.indices.contains(indexPath.item), model.engine.pathGuard.permits(items[indexPath.item].url) else {
            return nil
        }
        return items[indexPath.item].url as NSURL
    }

    private func dropFolder(at indexPath: IndexPath?, operation: NSCollectionView.DropOperation) -> URL? {
        if operation == .on, let indexPath, items.indices.contains(indexPath.item),
            items[indexPath.item].isBrowsableFolder, !items[indexPath.item].isSymbolicLink
        {
            return items[indexPath.item].url
        }
        return model.location.folderURL
    }

    func collectionView(
        _ collectionView: NSCollectionView, validateDrop info: NSDraggingInfo,
        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard model.engine.pathGuard.allowsWrites else { return [] }
        let path = proposedIndexPath.pointee as IndexPath
        if dropOperation.pointee == .on, !(items.indices.contains(path.item) && items[path.item].isBrowsableFolder) {
            dropOperation.pointee = .before
        }
        guard let folder = dropFolder(at: path, operation: dropOperation.pointee) else { return [] }
        return FileViewKeys.dropOperation(info, into: folder)
    }

    func collectionView(
        _ collectionView: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard let folder = dropFolder(at: indexPath, operation: dropOperation) else { return false }
        let urls = FileViewKeys.droppedURLs(info)
        let operation = FileViewKeys.dropOperation(info, into: folder)
        guard !urls.isEmpty, !operation.isEmpty else { return false }
        onDrop?(urls, folder, operation == .copy)
        return true
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChange?()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChange?()
    }
}

/// One icon with its name below, highlighted in Scope's selection colour.
@MainActor
final class IconItem: NSCollectionViewItem {
    private let icon = NSImageView()
    private let name = NSTextField(wrappingLabelWithString: "")
    private let background = NSView()
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!
    private var nameHidden: NSLayoutConstraint!

    override func loadView() {
        let root = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        name.textColor = Palette.primaryText
        for view in [background, icon, name] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 64)
        iconHeight = icon.heightAnchor.constraint(equalToConstant: 64)
        nameHidden = name.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            icon.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconWidth, iconHeight,
            // One rounded shape around both the icon and its name.
            background.topAnchor.constraint(equalTo: icon.topAnchor, constant: -4),
            background.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 1),
            background.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -1),
            background.bottomAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
            name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 6),
            name.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            name.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
        ])
        view = root
        imageView = icon
        textField = name
    }

    func show(_ file: FileItem, image: NSImage, iconSize: CGFloat, showsName: Bool) {
        icon.image = image
        iconWidth.constant = iconSize
        iconHeight.constant = iconSize
        name.stringValue = file.name
        name.isHidden = !showsName
        nameHidden.isActive = !showsName
        icon.alphaValue = file.isHidden ? 0.55 : 1
        view.toolTip = showsName ? nil : file.name
        updateHighlight()
    }

    override var isSelected: Bool {
        didSet { updateHighlight() }
    }

    private func updateHighlight() {
        // A layer's CGColor is fixed when it's made, so resolve it in the view's own appearance.
        var selection: CGColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance { selection = Palette.selection.cgColor }
        background.layer?.backgroundColor = isSelected ? selection : nil
    }

    override func viewWillLayout() {
        super.viewWillLayout()
        // Layer colours don't follow light and dark mode on their own.
        updateHighlight()
    }
}

/// Collection view with double-click, Finder's keys and pinch to resize.
@MainActor
final class IconCollectionView: NSCollectionView {
    var onDoubleClick: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onMagnify: ((Double) -> Void)?
    var onRightClick: ((NSPoint) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onRightClick?(convert(event.locationInWindow, from: nil))
        return super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(1 + event.magnification)
    }
}
