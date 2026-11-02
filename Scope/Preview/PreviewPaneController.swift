import AppKit
import Quartz
import ScopeEngine

/// The preview pane on the right of every view: a Quick Look preview of the
/// selected item and, below it, the details Finder's Get Info would show,
/// plus dimensions, camera and duration where they apply.
@MainActor
final class PreviewPaneController: NSViewController {
    private let engine: FileEngine
    private let preview = QLPreviewView(frame: .zero, style: .compact)!
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let grid = NSGridView()
    private let placeholder = NSTextField(labelWithString: "")
    private var loadTask: Task<Void, Never>?
    private var shownURL: URL?
    private var generation = 0

    init(engine: FileEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = BackgroundView(color: Palette.panelBackground)
        preview.shouldCloseWithWindow = false
        preview.autostarts = true
        nameLabel.font = .boldSystemFont(ofSize: 14)
        nameLabel.textColor = Palette.primaryText
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.alignment = .center
        subtitle.textColor = Palette.secondaryText
        subtitle.alignment = .center
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        placeholder.textColor = Palette.secondaryText
        placeholder.alignment = .center
        grid.rowSpacing = 5
        grid.columnSpacing = 8
        grid.xPlacement = .leading

        let detailsScroll = NSScrollView()
        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(grid)
        detailsScroll.documentView = flipped
        detailsScroll.drawsBackground = false
        detailsScroll.hasVerticalScroller = true
        detailsScroll.autohidesScrollers = true

        for view in [preview, nameLabel, subtitle, detailsScroll, placeholder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            preview.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.42),
            nameLabel.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 10),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            subtitle.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            detailsScroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            detailsScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            detailsScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            detailsScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            flipped.leadingAnchor.constraint(equalTo: detailsScroll.contentView.leadingAnchor),
            flipped.trailingAnchor.constraint(equalTo: detailsScroll.contentView.trailingAnchor),
            flipped.topAnchor.constraint(equalTo: detailsScroll.contentView.topAnchor),
            grid.topAnchor.constraint(equalTo: flipped.topAnchor),
            grid.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: flipped.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        view = root
        show(nil, count: 0)
    }

    /// Shows the single selected item, or a summary when none or several are selected.
    func show(_ item: FileItem?, count: Int) {
        generation += 1
        let generation = generation
        guard let item else {
            loadTask?.cancel()
            shownURL = nil
            preview.previewItem = nil
            setContentHidden(true)
            placeholder.stringValue = count == 0 ? "No selection" : "\(count) items selected"
            return
        }
        shownURL = item.url
        setContentHidden(false)
        nameLabel.stringValue = item.name
        subtitle.stringValue = item.kind
        fill(rows: basicRows(item))
        // Only items the path guard permits are handed to Quick Look.
        preview.previewItem = nil

        loadTask?.cancel()
        let engine = engine
        let url = item.url
        loadTask = Task { [weak self] in
            // Wait a moment so arrowing through a folder doesn't read every file.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let readable = await engine.readableURLs([url]).first
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.preview.previewItem = readable.map { $0 as NSURL }
            guard !Task.isCancelled, let details = try? await engine.details(for: url) else { return }
            guard self.generation == generation, !Task.isCancelled else { return }
            self.fill(rows: self.detailRows(details))
        }
    }

    func close() {
        generation += 1
        loadTask?.cancel()
        preview.close()
    }

    private func setContentHidden(_ hidden: Bool) {
        for view in [preview, nameLabel, subtitle, grid] as [NSView] { view.isHidden = hidden }
        placeholder.isHidden = !hidden
    }

    private func basicRows(_ item: FileItem) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let size = item.size { rows.append(("Size", Self.sizeText(size))) }
        rows.append(("Created", DateText.format(item.created)))
        rows.append(("Modified", DateText.format(item.modified)))
        rows.append(("Where", PathBar.displayPath(item.url.deletingLastPathComponent())))
        return rows
    }

    private func detailRows(_ details: ItemDetails) -> [(String, String)] {
        let item = details.item
        var rows: [(String, String)] = []
        if let count = details.folderItemCount { rows.append(("Contains", count == 1 ? "1 item" : "\(count) items")) }
        if let size = item.size { rows.append(("Size", Self.sizeText(size))) }
        if let width = details.pixelWidth, let height = details.pixelHeight {
            rows.append(("Dimensions", "\(width) × \(height)"))
        }
        if let camera = details.cameraModel { rows.append(("Camera", camera)) }
        if let taken = details.dateTaken { rows.append(("Taken", taken)) }
        if let duration = details.duration { rows.append(("Duration", Self.durationText(duration))) }
        if let target = details.linkTarget { rows.append(("Points to", target)) }
        rows.append(("Created", DateText.format(item.created)))
        rows.append(("Modified", DateText.format(item.modified)))
        if let opened = details.lastOpened { rows.append(("Last opened", DateText.format(opened))) }
        if !details.tags.isEmpty { rows.append(("Tags", details.tags.joined(separator: ", "))) }
        rows.append(("Where", PathBar.displayPath(item.url.deletingLastPathComponent())))
        return rows
    }

    private func fill(rows: [(String, String)]) {
        // Removing a grid row leaves its views behind, so take them out first.
        grid.subviews.forEach { $0.removeFromSuperview() }
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        for (label, value) in rows {
            let name = NSTextField(labelWithString: label)
            name.textColor = Palette.secondaryText
            name.alignment = .right
            name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            let text = CopyLabel(wrappingLabelWithString: value)
            text.textColor = Palette.primaryText
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.preferredMaxLayoutWidth = 170
            grid.addRow(with: [name, text])
        }
        if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .trailing }
    }

    static func sizeText(_ bytes: Int64) -> String {
        let short = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return bytes < 1000 ? short : "\(short) (\(bytes.formatted()) bytes)"
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

@MainActor
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A details value: one click copies it, with a short highlight to show it happened.
@MainActor
final class CopyLabel: NSTextField {
    convenience init(wrappingLabelWithString string: String) {
        self.init(frame: .zero)
        stringValue = string
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byWordWrapping
        cell?.wraps = true
        setup()
    }

    private func setup() {
        toolTip = "Click to copy"
        wantsLayer = true
        layer?.cornerRadius = 3
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(stringValue, forType: .string)
        var flash: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { flash = Palette.selection.cgColor }
        layer?.backgroundColor = flash
        let original = toolTip
        toolTip = "Copied"
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.3
                    self?.layer?.backgroundColor = nil
                }, completionHandler: nil)
            self?.toolTip = original
        }
    }
}
