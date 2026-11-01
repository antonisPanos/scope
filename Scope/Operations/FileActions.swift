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
            // The drawer stays closed: the footer and the toolbar button show progress.
            await OperationsController.shared.start(kind, from: window)
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

    /// Cut (Cmd+X): copies the selection, and the next paste moves it instead.
    func cutSelection() {
        copySelection()
        guard !selectedItems.isEmpty else { return }
        CutPasteboard.changeCount = NSPasteboard.general.changeCount
    }

    /// Whether the files on the pasteboard came from Cut and nothing was copied since.
    var pasteboardIsCut: Bool { CutPasteboard.changeCount == NSPasteboard.general.changeCount }

    func copyPathOfSelection() {
        let paths = (selectedItems.isEmpty ? [currentFolder].compactMap { $0 } : selectedItems.map(\.url)).map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    var pasteboardFiles: [URL] {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            ?? []
    }

    /// Pastes copied files into the current folder; `move` is Finder's "Move Item Here".
    func paste(move: Bool) {
        let files = pasteboardFiles
        guard let folder = currentFolder, !files.isEmpty else { return }
        let move = move || pasteboardIsCut
        // Cut items move once; pasting again would find nothing left to move.
        if pasteboardIsCut { CutPasteboard.changeCount = nil }
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
            let disk = BuildIdentity.testDiskRoots.first(where: { image.path.hasPrefix($0.path + "/") })
        {
            let name = (image.lastPathComponent as NSString).deletingPathExtension
            mountPoint = disk.appendingPathComponent("Mounted").appendingPathComponent(name)
        }
        startOperation(.mountImage(image, readOnly: readOnly, mountPoint: mountPoint))
    }

    func undoLastOperation() {
        let window = window
        Task { await OperationsController.shared.undoLast(from: window) }
    }

    /// Opens Get Info for the selection (up to five items), or the folder on screen.
    func showInfo() {
        let engine = model.engine
        let window = window
        if !selectedItems.isEmpty {
            for item in selectedItems.prefix(5) { InfoWindowController.show(for: item, engine: engine, near: window) }
            return
        }
        guard let folder = currentFolder else { return }
        Task {
            guard let item = try? await engine.item(at: folder) else { return }
            InfoWindowController.show(for: item, engine: engine, near: window)
        }
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
    /// copied when Option is held, as in Finder. `copy` is what the drag badge
    /// showed. A move is checked against the disks themselves, off the main
    /// thread, and becomes a copy when they differ, so a drop never moves more
    /// than the badge promised.
    func handleDrop(_ urls: [URL], onto folder: URL, copy: Bool) {
        if copy {
            startOperation(.copy(urls, into: folder))
            return
        }
        let engine = model.engine
        Task {
            let sameDisk = await engine.areOnSameDisk(urls, as: folder)
            startOperation(sameDisk ? .move(urls, into: folder) : .copy(urls, into: folder))
        }
    }

    // MARK: - Open With

    /// The file Open With is offered for: a single selected file or package.
    var openWithItem: FileItem? {
        guard selectedItems.count == 1, let item = selectedItems.first, !item.isBrowsableFolder else { return nil }
        return item
    }

    /// The apps that can open `url`, at most 20, the default one marked.
    /// Launch Services reads the file and the app bundles to answer, and the
    /// guard resolves the path, so this runs off the main thread. Empty when
    /// the guard refuses the file.
    nonisolated static func openWithApps(for url: URL, pathGuard: PathGuard) async -> [OpenWithApp] {
        await Task.detached(priority: .userInitiated) {
            guard pathGuard.permits(url) else { return [] }
            let workspace = NSWorkspace.shared
            let preferred = workspace.urlForApplication(toOpen: url)
            return workspace.urlsForApplications(toOpen: url).prefix(20).map { app in
                let name = FileManager.default.displayName(atPath: app.path)
                return OpenWithApp(
                    url: app, title: name + (app == preferred ? " (default)" : ""),
                    icon: workspace.icon(forFile: app.path))
            }
        }.value
    }

    /// The Open With menu line for one app.
    func openWithEntry(for app: OpenWithApp) -> NSMenuItem {
        let entry = NSMenuItem(title: app.title, action: #selector(openWithApp(_:)), keyEquivalent: "")
        entry.representedObject = app.url
        entry.target = self
        app.icon.size = NSSize(width: 16, height: 16)
        entry.image = app.icon
        return entry
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        let urls = selectedItems.map(\.url)
        let pathGuard = model.engine.pathGuard
        Task {
            let permitted = await Task.detached { urls.filter { pathGuard.permits($0) } }.value
            guard !permitted.isEmpty else { return }
            NSWorkspace.shared.open(
                permitted, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil)
        }
    }

    // MARK: - Standard Edit menu actions

    /// Edit > Cut (Cmd+X), when Settings allow it; the right-click Cut always works.
    @objc func cut(_ sender: Any?) {
        if AppSettings.shared.commandXCuts { cutSelection() }
    }
    @objc func copy(_ sender: Any?) { copySelection() }
    @objc func paste(_ sender: Any?) { paste(move: false) }
    @objc func undo(_ sender: Any?) { undoLastOperation() }
}

/// Remembers which pasteboard contents came from Cut, by the pasteboard's
/// change count, so copying anything else afterwards turns the next paste
/// back into a copy.
@MainActor
private enum CutPasteboard {
    static var changeCount: Int?
}

/// An app for the Open With menu, carried from the background lookup. The
/// icon is not touched again off the main thread.
struct OpenWithApp: @unchecked Sendable {
    let url: URL
    let title: String
    let icon: NSImage
}
