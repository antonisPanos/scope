import AppKit
import PandoraEngine

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

    private let pathControl = NSPathControl()
    private let field = PathField()
    private let errorLabel = NSTextField(labelWithString: "")
    private var location: Location?
    /// The folder behind each breadcrumb, in order.
    private var crumbURLs: [URL] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        pathControl.pathStyle = .standard
        pathControl.focusRingType = .none
        pathControl.isEditable = false
        pathControl.target = self
        pathControl.action = #selector(crumbClicked)
        pathControl.font = .systemFont(ofSize: NSFont.systemFontSize)
        pathControl.backgroundColor = .clear

        field.placeholderString = "Type a path, like ~/Documents or /Volumes/PandoraTest"
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.isHidden = true
        field.delegate = self
        field.onCancel = { [weak self] in self?.endEditing() }

        errorLabel.textColor = Palette.error
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byTruncatingTail

        for view in [pathControl, field, errorLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            pathControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            pathControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: errorLabel.leadingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
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
            pathControl.pathItems = crumbURLs.map(Self.crumb)
        case .recents, .tag:
            crumbURLs = []
            let item = NSPathControlItem()
            item.title = location.title
            item.image = NSImage(systemSymbolName: location.symbolName, accessibilityDescription: nil)
            pathControl.pathItems = [item]
        }
    }

    /// Switches to the text field with the current path selected.
    func beginEditing(prefill: String? = nil) {
        errorLabel.isHidden = true
        field.stringValue = prefill ?? location?.folderURL.map { Self.displayPath($0) } ?? ""
        field.isHidden = false
        pathControl.isHidden = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func endEditing() {
        field.isHidden = true
        errorLabel.isHidden = true
        pathControl.isHidden = false
        // Hand focus back to the file list.
        window?.makeFirstResponder(nextKeyView)
    }

    override func mouseDown(with event: NSEvent) {
        // A click on the bar's empty part, past the breadcrumbs, starts typing.
        if !isEditing { beginEditing() }
    }

    @objc private func crumbClicked() {
        guard let clicked = pathControl.clickedPathItem,
              let index = pathControl.pathItems.firstIndex(where: { $0 === clicked }),
              crumbURLs.indices.contains(index) else { return }
        onNavigate?(crumbURLs[index])
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

    private static func crumb(_ url: URL) -> NSPathControlItem {
        let item = NSPathControlItem()
        let isDisk = url.path == "/" || isVolumeRoot(url)
        item.title = url.path == "/" ? (Volumes.rootName ?? "Macintosh HD") : url.lastPathComponent
        item.image = NSImage(systemSymbolName: isDisk ? "externaldrive" : "folder", accessibilityDescription: nil)
        return item
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
