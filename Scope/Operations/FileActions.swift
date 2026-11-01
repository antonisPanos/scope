import AppKit
import ScopeEngine

/// The file operations a browser window offers: copy and paste, duplicate,
/// rename, new folder, Trash, compress, extract, mount, undo. Each one turns
/// into a `FileOperation` queued with the operations controller.
extension BrowserWindowController {
    /// The folder new items go into: the one on screen.
    var currentFolder: URL? { model.location.folderURL }

    func startOperation(_ kind: FileOperation.Kind) {
        let window = window
        Task {
            if await OperationsController.shared.start(kind, from: window) != nil {
                showActivity(true)
            }
        }
    }

    // MARK: - Pasteboard

    func copySelection() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    func copyPathOfSelection() {
        let paths = (selectedItems.isEmpty ? [currentFolder].compactMap { $0 } : selectedItems.map(\.url)).map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    var pasteboardFiles: [URL] {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Pastes copied files into the current folder; `move` is Finder's "Move Item Here".
    func paste(move: Bool) {
        let files = pasteboardFiles
        guard let folder = currentFolder, !files.isEmpty else { return }
        startOperation(move ? .move(files, into: folder) : .copy(files, into: folder))
    }

    // MARK: - Simple operations

    func duplicateSelection() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        startOperation(.duplicate(urls))
    }

    func trashSelection() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        startOperation(.trash(urls))
    }

    func compressSelection() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        startOperation(.compress(urls, format: .zip))
    }

    var archiveToExtract: URL? {
        selectedItems.count == 1 && FileEngine.isArchive(selectedItems[0].url) ? selectedItems[0].url : nil
    }

    func extractSelection() {
        guard let archive = archiveToExtract else { return }
        startOperation(.extract(archive))
    }

    var imageToMount: URL? {
        selectedItems.count == 1 && FileEngine.isDiskImage(selectedItems[0].url) ? selectedItems[0].url : nil
    }

    func mountSelection(readOnly: Bool = false) {
        guard let image = imageToMount else { return }
        // Development builds mount inside the test disk the image is on, so the
        // path guard lets Scope browse the mounted volume.
        var mountPoint: URL?
        if BuildIdentity.current.isDevelopment,
           let disk = BuildIdentity.testDiskRoots.first(where: { image.path.hasPrefix($0.path + "/") }) {
            let name = (image.lastPathComponent as NSString).deletingPathExtension
            mountPoint = disk.appendingPathComponent("Mounted").appendingPathComponent(name)
        }
        startOperation(.mountImage(image, readOnly: readOnly, mountPoint: mountPoint))
    }

    func undoLastOperation() {
        let window = window
        Task { await OperationsController.shared.undoLast(from: window) }
    }

    // MARK: - Names

    func renameSelection() {
        guard selectedItems.count == 1, let item = selectedItems.first else { return }
        askForName(title: "Rename “\(item.name)”", initial: item.name, button: "Rename") { [weak self] name in
            guard name != item.name else { return }
            self?.startOperation(.rename(item.url, to: name))
        }
    }

    func newFolder() {
        guard let folder = currentFolder else { return }
        askForName(title: "New Folder", initial: "untitled folder", button: "Create") { [weak self] name in
            self?.startOperation(.newFolder(in: folder, name: name))
        }
    }

    /// A small sheet with a name field; the part before the extension starts selected.
    private func askForName(title: String, initial: String, button: String, completion: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            completion(name)
        }
        let stem = (initial as NSString).deletingPathExtension
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem.isEmpty ? initial : stem).utf16.count)
    }

    // MARK: - Drops

    /// Files dropped on a folder: moved on the same disk, copied across disks,
    /// copied when Option is held, as in Finder.
    func handleDrop(_ urls: [URL], onto folder: URL, copy: Bool) {
        let sameDisk = urls.allSatisfy { Self.volume(of: $0) == Self.volume(of: folder) }
        startOperation(copy || !sameDisk ? .copy(urls, into: folder) : .move(urls, into: folder))
    }

    private static func volume(of url: URL) -> URL? {
        try? url.resourceValues(forKeys: [.volumeURLKey]).volume
    }

    // MARK: - Open With

    func openWithMenu() -> NSMenu? {
        guard selectedItems.count == 1, let item = selectedItems.first, !item.isBrowsableFolder,
              model.engine.pathGuard.permits(item.url) else { return nil }
        let menu = NSMenu(title: "Open With")
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: item.url)
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: item.url)
        for app in apps.prefix(20) {
            let title = FileManager.default.displayName(atPath: app.path) + (app == preferred ? " (default)" : "")
            let entry = NSMenuItem(title: title, action: #selector(openWithApp(_:)), keyEquivalent: "")
            entry.representedObject = app
            entry.target = self
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            menu.addItem(entry)
        }
        return menu.items.isEmpty ? nil : menu
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        let urls = selectedItems.map(\.url).filter { model.engine.pathGuard.permits($0) }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Standard Edit menu actions

    @objc func copy(_ sender: Any?) { copySelection() }
    @objc func paste(_ sender: Any?) { paste(move: false) }
    @objc func undo(_ sender: Any?) { undoLastOperation() }
}
