import AppKit
import ScopeEngine

/// Cmd+K: a search box over every command and sidebar place. Typing filters
/// by fuzzy match; Up and Down move, Return runs, Escape closes. Text that
/// looks like a path ("/", "~", "./") adds a "Go to" entry for it.
@MainActor
final class CommandPalette: NSObject {
    struct Entry {
        let title: String
        let detail: String
        let symbolName: String
        let run: () -> Void
    }

    private weak var controller: BrowserWindowController?
    private let panel: PalettePanel
    private let field = NSTextField()
    private let table = NSTableView()
    private var allEntries: [Entry] = []
    private var shown: [Entry] = []
    private var closing = false

    init(controller: BrowserWindowController) {
        self.controller = controller
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                             styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        buildUI()
    }

    /// Opens the palette; `prefill` starts it with text, such as a path to edit.
    func show(prefill: String = "") {
        guard let window = controller?.window, let controller else { return }
        allEntries = makeEntries(for: controller)
        field.stringValue = prefill
        filter()
        let frame = window.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 90))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() {
        guard !closing else { return }
        closing = true
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        closing = false
    }

    private func buildUI() {
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.onResignKey = { [weak self] in self?.close() }

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background

        field.placeholderString = "Type a command, a place, or a path"
        field.font = .systemFont(ofSize: 18)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self

        let column = NSTableColumn(identifier: .init("entry"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 30
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let divider = NSBox()
        divider.boxType = .separator
        for view in [field, divider, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            divider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            divider.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
        ])
    }

    private func makeEntries(for controller: BrowserWindowController) -> [Entry] {
        var entries: [Entry] = []
        for command in Commands.all where command.isEnabled(controller) && command.id != "palette" {
            let title = command.menu == .sortBy ? "Sort by \(command.title)" : command.title
            entries.append(Entry(title: title, detail: command.shortcutText, symbolName: "command") { [weak controller] in
                if let controller { command.run(controller) }
            })
        }
        for item in SidebarStore.shared.allItems where item.isEnabled {
            entries.append(Entry(title: "Go to \(item.title)", detail: item.kind == .tag ? "Tag" : "Place",
                                 symbolName: item.kind == .tag ? "tag" : item.symbolName) { [weak controller] in
                controller?.model.navigate(to: item.location)
            })
        }
        return entries
    }

    private func filter() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        var results: [Entry] = []
        if query.hasPrefix("/") || query.hasPrefix("~") || query.hasPrefix("./") || query.hasPrefix("../") {
            results.append(Entry(title: "Go to \(query)", detail: "Path", symbolName: "arrow.right.circle") { [weak controller] in
                controller?.goToTypedPath(query)
            })
        }
        if query.isEmpty {
            results += allEntries
        } else {
            results += allEntries
                .compactMap { entry in Self.score(query, in: entry.title).map { (entry, $0) } }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        shown = results
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    /// Fuzzy match: every query character must appear in order. Matches at the
    /// start of words and consecutive runs score higher.
    static func score(_ query: String, in text: String) -> Int? {
        let query = Array(query.lowercased())
        let text = Array(text.lowercased())
        var score = 0
        var queryIndex = 0
        var previousMatch = -2
        for (index, character) in text.enumerated() where queryIndex < query.count {
            guard character == query[queryIndex] else { continue }
            score += 1
            if index == previousMatch + 1 { score += 3 }
            if index == 0 || text[index - 1] == " " { score += 5 }
            previousMatch = index
            queryIndex += 1
        }
        return queryIndex == query.count ? score : nil
    }

    @objc private func runSelected() {
        let row = table.selectedRow
        guard shown.indices.contains(row) else { return }
        let entry = shown[row]
        close()
        entry.run()
    }

    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let row = max(0, min(shown.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
}

extension CommandPalette: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        filter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }
}

extension CommandPalette: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = shown[row]
        let cell = tableView.makeView(withIdentifier: .init("paletteCell"), owner: nil) as? PaletteCell ?? PaletteCell()
        cell.identifier = .init("paletteCell")
        cell.configure(entry)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }
}

@MainActor
private final class PaletteCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.contentTintColor = .controlAccentColor
        title.font = .systemFont(ofSize: 14)
        title.textColor = Palette.primaryText
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = Palette.secondaryText
        for view in [icon, title, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ entry: CommandPalette.Entry) {
        icon.image = NSImage(systemSymbolName: entry.symbolName, accessibilityDescription: nil)
        title.stringValue = entry.title
        detail.stringValue = entry.detail
    }
}

/// A borderless panel that can take keyboard focus and closes when it loses it.
@MainActor
final class PalettePanel: NSPanel {
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
