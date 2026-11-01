import AppKit
import PandoraEngine

/// The right-hand side of a browser tab: path bar, file list, status bar,
/// and a message in place of the list when a folder can't be shown.
@MainActor
final class BrowserViewController: NSViewController {
    let model: BrowserModel
    let pathBar = PathBar()
    let fileList: FileListViewController
    private let statusBar = NSView()
    private let statusLeft = NSTextField(labelWithString: "")
    private let statusRight = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let pathSeparator = NSBox()
    private let statusSeparator = NSBox()

    init(model: BrowserModel) {
        self.model = model
        self.fileList = FileListViewController(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = BackgroundView(color: Palette.windowBackground)
        addChild(fileList)

        pathSeparator.boxType = .separator
        statusSeparator.boxType = .separator
        statusLeft.textColor = Palette.secondaryText
        statusLeft.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusRight.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusRight.alignment = .right
        message.alignment = .center
        message.textColor = Palette.secondaryText
        message.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        for view in [statusLeft, statusRight] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            statusBar.addSubview(view)
        }
        let list = fileList.view
        for view in [pathBar, pathSeparator, list, statusSeparator, statusBar, message, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathSeparator.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            pathSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.topAnchor.constraint(equalTo: pathSeparator.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: statusSeparator.topAnchor),
            statusSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusSeparator.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
            statusLeft.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLeft.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusRight.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            statusRight.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusRight.leadingAnchor.constraint(greaterThanOrEqualTo: statusLeft.trailingAnchor, constant: 12),
            message.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor, constant: -60),
            spinner.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: list.centerYAnchor),
        ])
        pathBar.nextKeyView = fileList.view.subviews.first { $0 is NSClipView }?.subviews.first ?? fileList.view
        view = root
        update(.location)
        update([.state, .status])
    }

    func update(_ change: BrowserModel.Change) {
        if change.contains(.location) { pathBar.show(model.location) }
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
        if change.contains(.items), model.state == .loaded {
            message.isHidden = !model.items.isEmpty
            message.stringValue = Self.emptyText(for: model.location)
        }
        fileList.modelDidChange(change)
        if change.contains(.status) || change.contains(.items) { updateStatus() }
    }

    func updateStatus() {
        let count = model.items.count
        let selected = fileList.selectedItems.count
        var left = count == 1 ? "1 item" : "\(count.formatted()) items"
        if selected > 0 { left = "\(selected.formatted()) of \(left) selected" }
        if let available = model.availableCapacity {
            left += ", \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available"
        }
        statusLeft.stringValue = left
        if BuildIdentity.current.isDevelopment {
            statusRight.stringValue = "Pandora Dev · test disks only"
            statusRight.textColor = Palette.warning
        } else if !model.engine.pathGuard.allowsWrites {
            statusRight.stringValue = "Read-only build"
            statusRight.textColor = Palette.secondaryText
        } else {
            statusRight.stringValue = ""
        }
    }

    var isPathBarVisible: Bool {
        get { !pathBar.isHidden }
        set { pathBar.isHidden = !newValue; pathSeparator.isHidden = !newValue; collapse(pathBar, !newValue) }
    }

    var isStatusBarVisible: Bool {
        get { !statusBar.isHidden }
        set { statusBar.isHidden = !newValue; statusSeparator.isHidden = !newValue; collapse(statusBar, !newValue) }
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
        case .tag(let tag): "No items are tagged \(tag)" + (BuildIdentity.current.isDevelopment ? " on the test disks." : ".")
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
