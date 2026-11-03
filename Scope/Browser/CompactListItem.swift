import AppKit
import ScopeEngine

/// A compact filename row for the horizontally scrolling List view.
@MainActor
final class CompactListItem: NSCollectionViewItem {
    private let cell = FileNameCell()

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 4
        cell.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(cell)
        NSLayoutConstraint.activate([
            cell.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            cell.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            cell.topAnchor.constraint(equalTo: root.topAnchor),
            cell.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        textField = cell.textField
        imageView = cell.imageView
    }

    func show(_ file: FileItem, tags: [String]) {
        cell.configure(with: file, tags: tags)
        view.toolTip = file.name
        updateHighlight()
    }

    override var isSelected: Bool {
        didSet { updateHighlight() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateHighlight() }
    }

    override func viewWillLayout() {
        super.viewWillLayout()
        updateHighlight()
    }

    private func updateHighlight() {
        guard isViewLoaded else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let selected: Bool =
                switch highlightState {
                case .forSelection, .asDropTarget: true
                case .forDeselection: false
                default: isSelected
                }
            view.layer?.backgroundColor = selected ? Palette.selection.cgColor : nil
        }
    }
}

/// A mouse wheel moves through List's columns, just like a horizontal
/// trackpad gesture. Its document always stays at the top of the viewport.
@MainActor
final class HorizontalListScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let delta =
            abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else {
            super.scrollWheel(with: event)
            return
        }
        let step = event.hasPreciseScrollingDeltas ? 1 : horizontalLineScroll
        let clip = contentView
        let maximum = max(0, (documentView?.frame.maxX ?? 0) - clip.bounds.width)
        let x = min(maximum, max(0, clip.bounds.minX - delta * step))
        clip.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(clip)
        if !event.hasPreciseScrollingDeltas || event.phase == .began { flashScrollers() }
    }
}
