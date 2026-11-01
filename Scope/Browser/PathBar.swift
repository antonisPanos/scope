import AppKit
import ScopeEngine

/// The address bar at the top of each tab. It shows the location as clickable
/// breadcrumbs; click the empty part, press Cmd+L or Shift+Cmd+G, and it turns
/// into a text field that accepts a typed path (absolute, relative, ~, or a
/// pasted file URL).
@MainActor
final class PathBar: NSView {
    /// Called with a breadcrumb the user clicked.
    var onNavigate: ((URL) -> Void)?
    /// Called with typed text; returns an error message to show, or nil when it worked.
    var onSubmit: ((String) -> String?)?

    /// The breadcrumbs: our own buttons rather than NSPathControl, which drew
    /// nothing (while staying clickable) inside split view.
    private let pathControl = NSStackView()
    private let field = PathField()
    private let errorLabel = NSTextField(labelWithString: "")
    private var location: Location?
    /// The folder behind each breadcrumb, in order.
    private var crumbURLs: [URL] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        pathControl.orientation = .horizontal
        pathControl.spacing = 6

        field.placeholderString = "Type a path, like ~/Documents or /Volumes/ScopeTest"
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.bezelStyle = .roundedBezel
        // A quiet field: no animated focus ring, just the bezel.
        field.focusRingType = .none
        field.isHidden = true
        field.delegate = self
        field.onCancel = { [weak self] in self?.endEditing() }

        errorLabel.textColor = Palette.error
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byTruncatingTail

        for view in [pathControl, errorLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pathControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            pathControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.45),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        errorLabel.setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isEditing: Bool { !field.isHidden }

    func show(_ location: Location) {
        self.location = location
        switch location {
        case .folder(let url):
            crumbURLs = Self.crumbURLs(for: url)
            setCrumbs(
                crumbURLs.map { url in
                    let isDisk = url.path == "/" || Self.isVolumeRoot(url)
                    return (
                        url.path == "/" ? (Volumes.rootName ?? "Macintosh HD") : url.lastPathComponent,
                        isDisk ? "externaldrive" : "folder"
                    )
                })
        case .recents, .tag, .search:
            crumbURLs = []
            setCrumbs([(location.title, location.symbolName)])
        }
    }

    /// Switches to the text field with the current path selected.
    func beginEditing(prefill: String? = nil) {
        errorLabel.isHidden = true
        field.stringValue = prefill ?? location?.folderURL.map { Self.displayPath($0) } ?? ""
        // The text field joins the bar only while typing. Kept in the bar
        // while hidden, it stopped the whole bar from drawing in split view.
        if field.superview == nil {
            addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: errorLabel.leadingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        field.isHidden = false
        pathControl.isHidden = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func endEditing() {
        field.isHidden = true
        field.removeFromSuperview()
        errorLabel.isHidden = true
        pathControl.isHidden = false
        // Hand focus back to the file list.
        window?.makeFirstResponder(nextKeyView)
    }

    override func mouseDown(with event: NSEvent) {
        // A click on the bar's empty part, past the breadcrumbs, starts typing.
        if !isEditing { beginEditing() }
    }

    private func setCrumbs(_ crumbs: [(title: String, symbol: String)]) {
        pathControl.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, crumb) in crumbs.enumerated() {
            if index > 0 {
                let chevron = NSImageView(
                    image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
                chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
                chevron.contentTintColor = Palette.secondaryText
                pathControl.addArrangedSubview(chevron)
            }
            let button = NSButton(
                title: crumb.title, image: NSImage(systemSymbolName: crumb.symbol, accessibilityDescription: nil)!,
                target: self, action: #selector(crumbClicked(_:)))
            button.isBordered = false
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: NSFont.systemFontSize)
            button.contentTintColor = index == crumbs.count - 1 ? Palette.primaryText : Palette.secondaryText
            button.tag = index
            button.lineBreakMode = .byTruncatingMiddle
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            pathControl.addArrangedSubview(button)
        }
    }

    @objc private func crumbClicked(_ sender: NSButton) {
        guard crumbURLs.indices.contains(sender.tag) else { return }
        onNavigate?(crumbURLs[sender.tag])
    }

    private func submit() {
        guard let onSubmit else { return }
        if let error = onSubmit(field.stringValue) {
            errorLabel.stringValue = error
            errorLabel.isHidden = false
            NSSound.beep()
        } else {
            endEditing()
        }
    }

    /// Paths inside the home folder show as ~/…, like Terminal.
    static func displayPath(_ url: URL) -> String {
        let home = BuildIdentity.realHome.path
        if url.path == home { return "~" }
        if url.path.hasPrefix(home + "/") { return "~" + url.path.dropFirst(home.count) }
        return url.path
    }

    /// Breadcrumbs from the volume down: test disk paths start at the disk,
    /// everything else at the startup disk, as in Finder.
    private static func crumbURLs(for url: URL) -> [URL] {
        var urls: [URL] = []
        var current = url.standardizedFileURL
        while true {
            urls.insert(current, at: 0)
            if current.path == "/" || isVolumeRoot(current) { break }
            current = current.deletingLastPathComponent()
        }
        return urls
    }

    private static func isVolumeRoot(_ url: URL) -> Bool {
        let components = url.pathComponents
        return components.count == 3 && components[1] == "Volumes"
    }

}

extension PathBar: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Clicking elsewhere leaves the typed path; the breadcrumbs come back.
        if isEditing, errorLabel.isHidden { endEditing() }
    }
}

/// The path text field; Escape cancels editing.
@MainActor
final class PathField: NSTextField {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
