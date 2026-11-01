import AppKit
import Observation

/// One side of the window: a stack of tabs, each a full browser (path bar,
/// file view, preview, status bar). The tab strip shows only in split view;
/// with one side, the window's own macOS tabs do that job.
@MainActor
final class PaneController: NSViewController {
    private(set) var tabs: [BrowserViewController]
    private(set) var activeIndex = 0
    let strip = PaneTabStrip()
    private let container = NSView()
    private lazy var stripHost = PaneTabStripBar(strip: strip)

    var onActivate: ((PaneController) -> Void)?
    var onNewTab: ((PaneController) -> Void)?
    var onCloseTab: ((PaneController, Int) -> Void)?
    /// Right-click actions on a tab: close the others, duplicate, move to the other side.
    var onTabAction: ((PaneController, Int, PaneTabStrip.Action) -> Void)?

    var activeTab: BrowserViewController { tabs[activeIndex] }

    init(tab: BrowserViewController) {
        tabs = [tab]
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        strip.onSelect = { [weak self] index in self?.show(index) }
        strip.onClose = { [weak self] index in
            guard let self else { return }
            self.onCloseTab?(self, index)
        }
        strip.onNew = { [weak self] in
            guard let self else { return }
            self.onNewTab?(self)
        }
        strip.onAction = { [weak self] index, action in
            guard let self else { return }
            self.onTabAction?(self, index, action)
        }
        view = root
        install(activeTab)
        refreshStrip()
    }

    /// The strip sits in the visible tab, under its path bar. (Placed above
    /// the tab, at the top of the pane, it ended up hidden under the toolbar.)
    /// In split view the pane's path bar and tab strip live in a header that
    /// the window adds as a top accessory of the pane's split item. That is
    /// the place AppKit keeps clear of the toolbar's scroll edge effect;
    /// rows placed under the toolbar by hand get hidden by it.

    private(set) lazy var header: NSSplitViewItemAccessoryViewController = {
        let controller = NSSplitViewItemAccessoryViewController()
        let separator = NSBox()
        separator.boxType = .separator
        // Split view shows the tabs only; the path bar is a single-view feature.
        let stack = NSStackView(views: [stripHost])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        for view in [stripHost] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stripHost.heightAnchor.constraint(equalToConstant: 28).isActive = true
        // Inside the accessory too, keep clear of the floating sidebar.
        let holder = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(stack)
        NSLayoutConstraint.activate([
            // The accessory starts under the toolbar; its safe area starts below it.
            stack.topAnchor.constraint(equalTo: holder.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: holder.safeAreaLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: holder.safeAreaLayoutGuide.trailingAnchor),
        ])
        controller.view = holder
        return controller
    }()

    var showsTabStrip = false {
        didSet {
            activeTab.isPathBarVisible = !showsTabStrip
            refreshStrip()
        }
    }

    func addTab(_ tab: BrowserViewController) {
        tabs.append(tab)
        show(tabs.count - 1)
    }

    /// Removes a tab and returns it, so the caller can close its model.
    @discardableResult
    func removeTab(at index: Int) -> BrowserViewController? {
        guard tabs.count > 1, tabs.indices.contains(index) else { return nil }
        let removed = tabs.remove(at: index)
        removed.isPathBarVisible = true
        if removed.view.superview != nil {
            removed.view.removeFromSuperview()
            removed.removeFromParent()
        }
        activeIndex = min(activeIndex > index ? activeIndex - 1 : activeIndex, tabs.count - 1)
        install(activeTab)
        refreshStrip()
        onActivate?(self)
        return removed
    }

    func show(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let old = activeTab
        activeIndex = index
        if old !== activeTab {
            old.isPathBarVisible = true
            old.view.removeFromSuperview()
            old.removeFromParent()
            install(activeTab)
        }
        refreshStrip()
        onActivate?(self)
        activeTab.fileView.focus()
    }

    private func install(_ tab: BrowserViewController) {
        guard tab.parent == nil else { return }
        defer { tab.isPathBarVisible = !showsTabStrip }
        addChild(tab)
        let subview = tab.view
        subview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: container.topAnchor),
            subview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            subview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Updates the tab titles; call when a tab's location changes.
    func refreshStrip() {
        strip.titles = tabs.map { $0.model.location.title }
        strip.activeIndex = activeIndex
        stripHost.rebuild()
    }

    var isFocused = false {
        didSet {
            strip.isFocused = isFocused
            stripHost.rebuild()
        }
    }

    func contains(_ view: NSView) -> Bool {
        view.isDescendant(of: self.view)
    }
}

/// The titles and state the tab strip draws.
@MainActor
@Observable
final class PaneTabStrip {
    var titles: [String] = []
    var activeIndex = 0
    var isFocused = false
    @ObservationIgnored var onSelect: ((Int) -> Void)?
    @ObservationIgnored var onClose: ((Int) -> Void)?
    @ObservationIgnored var onNew: (() -> Void)?
    @ObservationIgnored var onAction: ((Int, Action) -> Void)?

    enum Action { case closeOthers, duplicate, moveToOtherSide }
}

/// The tab strip above a pane in split view: a button per tab with a close
/// box, and a + for a new tab. The focused pane's active tab is tinted.
@MainActor
final class PaneTabStripBar: NSView {
    private let strip: PaneTabStrip
    private let stack = NSStackView()

    init(strip: PaneTabStrip) {
        self.strip = strip
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Palette.sidebarBackground.setFill()
        dirtyRect.fill()
        Palette.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, title) in strip.titles.enumerated() {
            stack.addArrangedSubview(tabView(index: index, title: title))
        }
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")!,
                           target: self, action: #selector(newTab))
        add.isBordered = false
        add.toolTip = "New Tab on This Side (⌘T)"
        stack.addArrangedSubview(add)
    }

    private func tabView(index: Int, title: String) -> NSView {
        let active = index == strip.activeIndex
        let box = TabBox()
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        var fill: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = active ? (strip.isFocused ? Palette.selection : Palette.separator).cgColor : nil
        }
        box.layer?.backgroundColor = fill
        box.onClick = { [weak self] in self?.strip.onSelect?(index) }
        box.menu = tabMenu(index)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: active ? .semibold : .regular)
        label.textColor = Palette.primaryText
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label])
        row.spacing = 4
        if strip.titles.count > 1 {
            let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")!,
                                 target: self, action: #selector(closeTab(_:)))
            close.isBordered = false
            close.tag = index
            close.symbolConfiguration = .init(pointSize: 8, weight: .bold)
            row.addArrangedSubview(close)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            box.heightAnchor.constraint(equalToConstant: 22),
        ])
        return box
    }

    private func tabMenu(_ index: Int) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ handler: @escaping () -> Void, enabled: Bool = true) {
            let item = MenuActionItem(title: title, handler: handler)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        let many = strip.titles.count > 1
        add("New Tab") { [weak self] in self?.strip.onNew?() }
        add("Duplicate Tab") { [weak self] in self?.strip.onAction?(index, .duplicate) }
        add("Move Tab to Other Side") { [weak self] in self?.strip.onAction?(index, .moveToOtherSide) }
        menu.addItem(.separator())
        add("Close Tab", { [weak self] in self?.strip.onClose?(index) }, enabled: many)
        add("Close Other Tabs", { [weak self] in self?.strip.onAction?(index, .closeOthers) }, enabled: many)
        menu.autoenablesItems = false
        return menu
    }

    @objc private func newTab() { strip.onNew?() }
    @objc private func closeTab(_ sender: NSButton) { strip.onClose?(sender.tag) }
}

@MainActor
private final class TabBox: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// The window's content beside the sidebar: one pane, or two side by side.
@MainActor
final class WorkspaceController: NSViewController {
    private(set) var panes: [PaneController]
    private(set) var activePaneIndex = 0
    private let split = NSSplitView()

    var activePane: PaneController { panes[activePaneIndex] }
    var activeContent: BrowserViewController { activePane.activeTab }
    var isSplit: Bool { panes.count == 2 }
    var otherPane: PaneController? { isSplit ? panes[1 - activePaneIndex] : nil }

    init(pane: PaneController) {
        panes = [pane]
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        split.isVertical = true
        split.dividerStyle = .thin
        addChild(panes[0])
        split.addArrangedSubview(panes[0].view)
        view = split
    }

    /// Records the second pane. The window shows it as its own split item
    /// beside this one: nested inside this view, its top rows ended up hidden
    /// under the toolbar.
    func addPane(_ pane: PaneController) {
        guard panes.count == 1 else { return }
        panes.append(pane)
        for pane in panes { pane.showsTabStrip = true }
    }

    /// Forgets the right-hand pane and returns it, so the window can remove
    /// its split item and close its tabs.
    func removeRightPane() -> PaneController? {
        guard isSplit else { return nil }
        let removed = panes.removeLast()
        activePaneIndex = 0
        panes[0].showsTabStrip = false
        panes[0].isFocused = false
        return removed
    }

    /// Makes the pane holding `view` the active one. Returns true when that changed.
    @discardableResult
    func activate(containing view: NSView) -> Bool {
        guard let index = panes.firstIndex(where: { $0.contains(view) }) else { return false }
        return activate(index)
    }

    @discardableResult
    func activate(_ index: Int) -> Bool {
        guard panes.indices.contains(index) else { return false }
        let changed = index != activePaneIndex
        activePaneIndex = index
        for (position, pane) in panes.enumerated() { pane.isFocused = isSplit && position == index }
        return changed
    }

    func pane(containing content: BrowserViewController) -> PaneController? {
        panes.first { $0.tabs.contains { $0 === content } }
    }

    var allContents: [BrowserViewController] { panes.flatMap(\.tabs) }
}

/// A menu item that runs a closure, for small menus built in code.
@MainActor
final class MenuActionItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
