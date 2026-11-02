import AppKit
import ScopeEngine
import SwiftUI

/// The right-hand side of a browser tab: path bar, the file view for the
/// current view mode, the preview pane, and the status bar with the icon size
/// slider. A message replaces the files when a folder can't be shown.
@MainActor
final class BrowserViewController: NSViewController {
    let model: BrowserModel
    let pathBar = PathBar()
    private(set) var fileView: FileBrowsingView
    private let preview: PreviewPaneController
    private let fileContainer = NSView()
    private let split = NSSplitView()
    private let statusBar = NSView()
    private let statusLeft = NSTextField(labelWithString: "")
    private let statusRight = NSTextField(labelWithString: "")
    private let sizeSlider = NSSlider()
    private let zoomLabel = NSTextField(labelWithString: "")
    private let zoomReset = NSButton()
    private var zoomLabelHide: Task<Void, Never>?
    /// Sizes the slider snaps to when it comes close.
    private static let zoomStops: [Double] = [16, 24, 32, 48, 64, 96, 128, 192, 256]
    private static let defaultZoom: Double = 64
    private let message = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let pathSeparator = NSBox()
    private let statusSeparator = NSBox()
    private var sizeObserver: NSObjectProtocol?

    /// Set by the window; handed to whichever file view is showing.
    var onOpen: (([FileItem]) -> Void)? { didSet { fileView.onOpen = onOpen } }
    var onQuickLook: (() -> Void)? { didSet { fileView.onQuickLook = onQuickLook } }
    var onSelectionChange: (() -> Void)?
    var onShowActivity: (() -> Void)?
    private lazy var footerActivity = NSHostingView(
        rootView: FooterActivity(
            controller: OperationsController.shared, action: { [weak self] in self?.onShowActivity?() }))
    var onDrop: (([URL], URL, Bool) -> Void)? { didSet { fileView.onDrop = onDrop } }
    var onRename: (() -> Void)? { didSet { fileView.onRename = onRename } }
    var onShortcut: ((FileViewKeys.Action) -> Void)? { didSet { fileView.onShortcut = onShortcut } }
    var contextMenu: NSMenu? { didSet { fileView.contextMenu = contextMenu } }
    /// Set by the window: what the activity drawer's Undo button does.
    var onUndoOperation: ((UUID) -> Void)?

    private lazy var activity = NSHostingView(
        rootView: ActivityPanel(
            controller: OperationsController.shared,
            onUndo: { [weak self] id in self?.onUndoOperation?(id) },
            onClose: { [weak self] in self?.isActivityVisible = false }))
    private let activitySeparator = NSBox()
    /// The search filters for this tab, and the bar that shows them during a search.
    let search = SearchSettings()
    var onSearchChange: (() -> Void)?
    var onEndSearch: (() -> Void)?
    private lazy var searchHost = NSHostingView(rootView: makeSearchBar())
    private let searchSeparator = NSBox()
    /// A row under the path bar for the pane's tab strip in split view.
    private let accessory = NSView()
    private var accessoryHeight: NSLayoutConstraint!
    private var searchHeight: NSLayoutConstraint!
    private var activityHeight: NSLayoutConstraint!

    init(model: BrowserModel) {
        self.model = model
        self.fileView = Self.makeView(for: model.viewMode, model: model)
        self.preview = PreviewPaneController(engine: model.engine)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let sizeObserver { NotificationCenter.default.removeObserver(sizeObserver) }
    }

    private static func makeView(for mode: ViewMode, model: BrowserModel) -> FileBrowsingView {
        switch mode {
        case .details, .list: FileListViewController(model: model)
        case .icons: IconGridViewController(model: model, style: .grid)
        case .columns: ColumnViewController(model: model)
        case .gallery: GalleryViewController(model: model)
        }
    }

    override func loadView() {
        let root = BackgroundView(color: Palette.windowBackground)
        addChild(preview)

        pathSeparator.boxType = .separator
        statusSeparator.boxType = .separator
        statusLeft.textColor = Palette.secondaryText
        statusLeft.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLeft.lineBreakMode = .byTruncatingTail
        statusRight.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusRight.alignment = .right
        message.alignment = .center
        message.textColor = Palette.secondaryText
        message.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        sizeSlider.minValue = AppSettings.iconSizes.lowerBound
        sizeSlider.maxValue = AppSettings.iconSizes.upperBound
        sizeSlider.doubleValue = AppSettings.shared.iconSize
        sizeSlider.controlSize = .small
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        sizeSlider.toolTip = "Icon size (⌘+ and ⌘−, or pinch)"
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        zoomLabel.textColor = Palette.secondaryText
        zoomLabel.alphaValue = 0
        zoomReset.image = NSImage(
            systemSymbolName: "arrow.uturn.backward.circle", accessibilityDescription: "Reset icon size")
        zoomReset.isBordered = false
        zoomReset.toolTip = "Reset icon size"
        zoomReset.target = self
        zoomReset.action = #selector(resetZoom)
        sizeObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.iconSizeDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sizeSlider.doubleValue = AppSettings.shared.iconSize
                self?.showZoomLabel()
            }
        }

        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "BrowserPreviewSplit"
        split.addArrangedSubview(fileContainer)
        split.addArrangedSubview(preview.view)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        preview.view.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true

        footerActivity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [statusLeft, footerActivity, zoomLabel, zoomReset, sizeSlider, statusRight] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            statusBar.addSubview(view)
        }
        activitySeparator.boxType = .separator
        searchSeparator.boxType = .separator
        for view in [
            pathBar, pathSeparator, accessory, searchHost, searchSeparator, split, activitySeparator, activity,
            statusSeparator, statusBar, message, spinner,
        ] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        // Everything keeps to the safe area: the sidebar floats over the
        // content, and rows pinned to the edge ended up hidden behind it.
        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            pathSeparator.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            pathSeparator.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            pathSeparator.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            accessory.topAnchor.constraint(equalTo: pathSeparator.bottomAnchor),
            accessory.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            accessory.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            searchHost.topAnchor.constraint(equalTo: accessory.bottomAnchor),
            searchHost.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            searchHost.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            searchSeparator.topAnchor.constraint(equalTo: searchHost.bottomAnchor),
            searchSeparator.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            searchSeparator.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            split.topAnchor.constraint(equalTo: searchSeparator.bottomAnchor),
            // The file views handle the sidebar themselves (scroll views inset
            // their content); tying this split view to the safe area made
            // AppKit's constraints conflict and crash when the sidebar toggled.
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: activitySeparator.topAnchor),
            activitySeparator.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            activitySeparator.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            activitySeparator.bottomAnchor.constraint(equalTo: activity.topAnchor),
            activity.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            activity.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            activity.bottomAnchor.constraint(equalTo: statusSeparator.topAnchor),
            statusSeparator.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            statusSeparator.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            statusSeparator.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
            statusLeft.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLeft.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            sizeSlider.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            sizeSlider.widthAnchor.constraint(equalToConstant: 110),
            footerActivity.leadingAnchor.constraint(equalTo: statusLeft.trailingAnchor, constant: 16),
            footerActivity.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            zoomLabel.leadingAnchor.constraint(greaterThanOrEqualTo: footerActivity.trailingAnchor, constant: 12),
            zoomLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            zoomReset.leadingAnchor.constraint(equalTo: zoomLabel.trailingAnchor, constant: 6),
            zoomReset.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            sizeSlider.leadingAnchor.constraint(equalTo: zoomReset.trailingAnchor, constant: 6),
            statusRight.leadingAnchor.constraint(equalTo: sizeSlider.trailingAnchor, constant: 12),
            statusRight.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            statusRight.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            message.centerXAnchor.constraint(equalTo: fileContainer.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: fileContainer.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: fileContainer.widthAnchor, constant: -60),
            spinner.centerXAnchor.constraint(equalTo: fileContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: fileContainer.centerYAnchor),
        ])
        statusLeft.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessoryHeight = accessory.heightAnchor.constraint(equalToConstant: 0)
        accessoryHeight.isActive = true
        // SwiftUI hosts otherwise impose their content's minimum width on the
        // window, even while hidden; two panes then can't fit the screen.
        searchHost.sizingOptions = []
        activity.sizingOptions = []
        footerActivity.sizingOptions = [.intrinsicContentSize]
        searchHeight = searchHost.heightAnchor.constraint(equalToConstant: 0)
        searchHeight.isActive = true
        searchHost.isHidden = true
        searchSeparator.isHidden = true
        activityHeight = activity.heightAnchor.constraint(equalToConstant: 0)
        activityHeight.isActive = true
        activity.isHidden = true
        activitySeparator.isHidden = true
        view = root
        install(fileView)
        isPreviewVisible = AppSettings.shared.showPreviewPane
        update(.location)
        update([.state, .status])
    }

    // MARK: - File views

    private func install(_ newView: FileBrowsingView) {
        addChild(newView)
        let subview = newView.view
        subview.translatesAutoresizingMaskIntoConstraints = false
        fileContainer.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: fileContainer.topAnchor),
            subview.leadingAnchor.constraint(equalTo: fileContainer.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: fileContainer.trailingAnchor),
            subview.bottomAnchor.constraint(equalTo: fileContainer.bottomAnchor),
        ])
        newView.onOpen = onOpen
        newView.onQuickLook = onQuickLook
        newView.onDrop = onDrop
        newView.onRename = onRename
        newView.onShortcut = onShortcut
        newView.contextMenu = contextMenu
        newView.onSelectionChange = { [weak self] in self?.selectionDidChange() }
        pathBar.nextKeyView = subview
        sizeSlider.isHidden = model.viewMode != .icons
        zoomReset.isHidden = sizeSlider.isHidden || AppSettings.shared.iconSize == Self.defaultZoom
    }

    /// Swaps in the view for the model's view mode, keeping the selection.
    private func switchViewIfNeeded() {
        let wantsList = model.viewMode == .details || model.viewMode == .list
        let matches: Bool =
            switch fileView {
            case is FileListViewController: wantsList
            case is IconGridViewController: model.viewMode == .icons
            case is ColumnViewController: model.viewMode == .columns
            case is GalleryViewController: model.viewMode == .gallery
            default: false
            }
        sizeSlider.isHidden = model.viewMode != .icons
        zoomReset.isHidden = sizeSlider.isHidden || AppSettings.shared.iconSize == Self.defaultZoom
        guard !matches else { return }

        let selection = fileView.selectedItems.map(\.url)
        let hadFocus = (view.window?.firstResponder as? NSView)?.isDescendant(of: fileView.view) ?? false
        (fileView as? GalleryViewController)?.close()
        fileView.view.removeFromSuperview()
        fileView.removeFromParent()
        fileView = Self.makeView(for: model.viewMode, model: model)
        install(fileView)
        fileView.select(selection, scroll: true)
        if hadFocus { fileView.focus() }
        selectionDidChange()
    }

    private func selectionDidChange() {
        let selected = fileView.selectedItems
        preview.show(selected.count == 1 ? selected[0] : nil, count: selected.count)
        updateStatus()
        onSelectionChange?()
    }

    // MARK: - Model updates

    func update(_ change: BrowserModel.Change) {
        if change.contains(.location) { pathBar.show(model.location) }
        if change.contains(.viewMode) { switchViewIfNeeded() }
        if change.contains(.state) {
            switch model.state {
            case .loading:
                message.isHidden = true
                // Only show the spinner when loading takes a moment.
                spinner.stopAnimation(nil)
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    if self?.model.state == .loading { self?.spinner.startAnimation(nil) }
                }
            case .loaded:
                spinner.stopAnimation(nil)
                message.isHidden = !model.items.isEmpty
                message.stringValue = Self.emptyText(for: model.location)
            case .failed(let text):
                spinner.stopAnimation(nil)
                message.isHidden = false
                message.stringValue = text
            }
        }
        if !change.isDisjoint(with: .anyItems), model.state == .loaded {
            message.isHidden = !model.items.isEmpty
            message.stringValue = Self.emptyText(for: model.location)
        }
        fileView.modelDidChange(change)
        if !change.isDisjoint(with: [.anyItems, .location]) { selectionDidChange() }
        if !change.isDisjoint(with: [.anyItems, .location, .status]) { updateSearchBar() }
        if change.contains(.status) { updateStatus() }
    }

    func updateStatus() {
        let count = model.items.count
        let selected = fileView.selectedItems.count
        var left = count == 1 ? "1 item" : "\(count.formatted()) items"
        if selected > 0 { left = "\(selected.formatted()) of \(left) selected" }
        if let available = model.availableCapacity {
            left += ", \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available"
        }
        statusLeft.stringValue = left
        if BuildIdentity.current.isDevelopment {
            statusRight.stringValue = "Scope Dev · test disks only"
            statusRight.textColor = Palette.warning
        } else if !model.engine.pathGuard.allowsWrites {
            statusRight.stringValue = "Read-only build"
            statusRight.textColor = Palette.secondaryText
        } else {
            statusRight.stringValue = ""
        }
    }

    private func makeSearchBar() -> SearchBar {
        SearchBar(
            settings: search, tags: SidebarStore.shared.tags.compactMap(\.tagName),
            resultCount: model.location.isSearch ? model.items.count : 0, isSearching: model.isSearching,
            onChange: { [weak self] in self?.onSearchChange?() },
            onStop: { [weak self] in self?.model.stopSearch() },
            onClose: { [weak self] in self?.onEndSearch?() })
    }

    private func updateSearchBar() {
        let visible = model.location.isSearch
        searchHost.isHidden = !visible
        searchSeparator.isHidden = !visible
        searchHeight.constant = visible ? 30 : 0
        if visible { searchHost.rootView = makeSearchBar() }
    }

    /// Snaps to the nearest stop when within a few points of it.
    @objc private func sizeChanged() {
        var size = sizeSlider.doubleValue
        if let stop = Self.zoomStops.min(by: { abs($0 - size) < abs($1 - size) }),
            abs(stop - size) <= max(3, stop * 0.08)
        {
            size = stop
            sizeSlider.doubleValue = stop
        }
        AppSettings.shared.iconSize = size
    }

    @objc private func resetZoom() {
        AppSettings.shared.iconSize = Self.defaultZoom
    }

    /// Shows the zoom level next to the slider while it changes, then fades it out.
    private func showZoomLabel() {
        let size = AppSettings.shared.iconSize
        zoomLabel.stringValue = "\(Int((size / Self.defaultZoom * 100).rounded()))%"
        zoomReset.isHidden = sizeSlider.isHidden || size == Self.defaultZoom
        guard !sizeSlider.isHidden else { return }
        zoomLabel.animator().alphaValue = 1
        zoomLabelHide?.cancel()
        zoomLabelHide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.4
                    self?.zoomLabel.animator().alphaValue = 0
                }, completionHandler: nil)
        }
    }

    func close() {
        preview.close()
        (fileView as? GalleryViewController)?.close()
    }

    // MARK: - Bars and panes

    var isPathBarVisible: Bool {
        get { !pathBar.isHidden }
        set {
            pathBar.isHidden = !newValue
            pathSeparator.isHidden = !newValue
            collapse(pathBar, !newValue)
        }
    }

    var isStatusBarVisible: Bool {
        get { !statusBar.isHidden }
        set {
            statusBar.isHidden = !newValue
            statusSeparator.isHidden = !newValue
            collapse(statusBar, !newValue)
        }
    }

    /// Shows `view` in the row under the path bar, or empties it.
    func setAccessory(_ view: NSView?, height: CGFloat) {
        _ = self.view
        accessory.subviews.forEach { $0.removeFromSuperview() }
        accessoryHeight.constant = view == nil ? 0 : height
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: accessory.topAnchor),
            view.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
        ])
    }

    /// The activity drawer at the bottom of the window.
    var isActivityVisible: Bool {
        get { !activity.isHidden }
        set {
            if newValue { OperationsController.shared.markAllRead() }
            activity.isHidden = !newValue
            activitySeparator.isHidden = !newValue
            activityHeight.constant = newValue ? 200 : 0
        }
    }

    var isPreviewVisible: Bool {
        get { !preview.view.isHidden }
        set {
            preview.view.isHidden = !newValue
            AppSettings.shared.showPreviewPane = newValue
            split.adjustSubviews()
            if newValue, preview.view.frame.width < 200 {
                split.setPosition(split.bounds.width - 280, ofDividerAt: 0)
            }
        }
    }

    private func collapse(_ bar: NSView, _ collapsed: Bool) {
        for constraint in bar.constraints where constraint.firstAttribute == .height && constraint.secondItem == nil {
            constraint.constant = collapsed ? 0 : (bar === pathBar ? 30 : 24)
        }
    }

    private static func emptyText(for location: Location) -> String {
        switch location {
        case .folder: "This folder is empty."
        case .recents: "Nothing opened recently" + (BuildIdentity.current.isDevelopment ? " on the test disks." : ".")
        case .tag(let tag):
            "No items are tagged \(tag)" + (BuildIdentity.current.isDevelopment ? " on the test disks." : ".")
        case .search: "Nothing found."
        }
    }
}

/// A plain view filled with one colour, following light and dark mode.
@MainActor
final class BackgroundView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}
