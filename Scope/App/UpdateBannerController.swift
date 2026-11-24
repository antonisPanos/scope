import AppKit

@MainActor
final class UpdateBannerController: NSTitlebarAccessoryViewController {
    let version: ReleaseVersion
    private let openRelease: (URL) -> Void
    private let onDismiss: () -> Void

    init(
        version: ReleaseVersion,
        openRelease: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        onDismiss: @escaping () -> Void
    ) {
        self.version = version
        self.openRelease = openRelease
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let height: CGFloat = 32
        let root = BannerView(frame: NSRect(x: 0, y: 0, width: 560, height: height))
        let label = NSTextField(labelWithString: "Scope \(version) is available.")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let release = NSButton(title: "View Release", target: self, action: #selector(viewRelease))
        let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissNotice))
        for button in [release, dismiss] { button.controlSize = .small }

        let row = NSStackView(views: [label, release, dismiss])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
        ])
        view = root
        fullScreenMinHeight = height
    }

    @objc private func viewRelease() { openRelease(version.releasePage) }

    @objc private func dismissNotice() { onDismiss() }

    private final class BannerView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            // Split view dividers extend into the titlebar behind the banner.
            Palette.windowBackground.setFill()
            dirtyRect.intersection(bounds).fill()
        }
    }
}
