import AppKit
import Quartz
import ScopeEngine

/// The gallery view: a large Quick Look preview of the selected item above a
/// strip of thumbnails. Left and Right move through the strip.
@MainActor
final class GalleryViewController: NSViewController, FileBrowsingView {
    let model: BrowserModel
    private let strip: IconGridViewController
    private let preview = QLPreviewView(frame: .zero, style: .normal)!
    private let caption = NSTextField(labelWithString: "")

    var onOpen: (([FileItem]) -> Void)? {
        get { strip.onOpen }
        set { strip.onOpen = newValue }
    }
    var onQuickLook: (() -> Void)? {
        get { strip.onQuickLook }
        set { strip.onQuickLook = newValue }
    }
    var onSelectionChange: (() -> Void)?
    var onDrop: (([URL], URL, Bool) -> Void)? {
        get { strip.onDrop }
        set { strip.onDrop = newValue }
    }
    var onRename: (() -> Void)? {
        get { strip.onRename }
        set { strip.onRename = newValue }
    }
    var onShortcut: ((FileViewKeys.Action) -> Void)? {
        get { strip.onShortcut }
        set { strip.onShortcut = newValue }
    }
    var contextMenu: NSMenu? {
        get { strip.contextMenu }
        set { strip.contextMenu = newValue }
    }

    func prepareForContextMenu() {}

    init(model: BrowserModel) {
        self.model = model
        self.strip = IconGridViewController(model: model, style: .strip)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = BackgroundView(color: Palette.windowBackground)
        addChild(strip)
        preview.shouldCloseWithWindow = false
        preview.autostarts = true
        caption.alignment = .center
        caption.textColor = Palette.secondaryText
        caption.lineBreakMode = .byTruncatingMiddle
        let separator = NSBox()
        separator.boxType = .separator
        let stripView = strip.view
        for view in [preview, caption, separator, stripView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            caption.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 6),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            separator.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stripView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            stripView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stripView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stripView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stripView.heightAnchor.constraint(equalToConstant: 92),
        ])
        strip.onSelectionChange = { [weak self] in
            self?.updatePreview()
            self?.onSelectionChange?()
        }
        view = root
        updatePreview()
    }

    func modelDidChange(_ change: BrowserModel.Change) {
        strip.modelDidChange(change)
        if !change.isDisjoint(with: .anyItems) {
            // The gallery always shows something: pick the first item if nothing is selected.
            if strip.selectedItems.isEmpty, let first = model.items.first, model.pendingSelection.isEmpty {
                strip.select([first.url], scroll: true)
            }
            updatePreview()
        }
    }

    var selectedItems: [FileItem] { strip.selectedItems }

    @discardableResult
    func select(_ urls: [URL], scroll: Bool) -> Bool {
        strip.select(urls, scroll: scroll)
    }

    func focus() {
        strip.focus()
    }

    func close() {
        preview.close()
    }

    private func updatePreview() {
        guard let item = strip.selectedItems.first else {
            preview.previewItem = nil
            caption.stringValue = ""
            return
        }
        caption.stringValue = item.name
        if (preview.previewItem as? NSURL) as URL? != item.url {
            preview.previewItem = model.engine.pathGuard.permits(item.url) ? item.url as NSURL : nil
        }
    }
}
