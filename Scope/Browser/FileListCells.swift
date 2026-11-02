import AppKit
import ScopeEngine

/// Icon plus name. Symlinks and aliases get Finder's small arrow badge.
@MainActor
final class FileNameCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badge = NSImageView()

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        // Image views accept dropped files by default, which would take the
        // drop away from the row under them.
        icon.unregisterDraggedTypes()
        badge.unregisterDraggedTypes()
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

/// Selection drawn in Scope's selection colour, with the text staying dark
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
    var onShortcut: ((FileViewKeys.Action) -> Void)?

    override func keyDown(with event: NSEvent) {
        if FileViewKeys.isArrowWithoutSelection(event, hasSelection: selectedRow >= 0), numberOfRows > 0 {
            selectRowIndexes([0], byExtendingSelection: false)
            scrollRowToVisible(0)
            return
        }
        switch FileViewKeys.action(for: event) {
        case .open?: onOpenSelection?()
        case .quickLook?: onQuickLook?()
        case .rename?: onRename?()
        case let other?: onShortcut?(other)
        case nil: super.keyDown(with: event)
        }
    }
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
