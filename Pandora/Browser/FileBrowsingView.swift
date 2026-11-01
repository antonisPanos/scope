import AppKit
import PandoraEngine

/// What every file view (details, list, icons, columns, gallery) offers the
/// browser, so the browser can swap one for another and keep the selection.
@MainActor
protocol FileBrowsingView: NSViewController {
    /// The user opened items (double-click, Cmd+Down, Cmd+O).
    var onOpen: (([FileItem]) -> Void)? { get set }
    var onSelectionChange: (() -> Void)? { get set }
    /// The user pressed Space.
    var onQuickLook: (() -> Void)? { get set }
    var selectedItems: [FileItem] { get }
    func modelDidChange(_ change: BrowserModel.Change)
    @discardableResult func select(_ urls: [URL], scroll: Bool) -> Bool
    func focus()
    /// The right-click menu; the view shows it over its items and empty space.
    var contextMenu: NSMenu? { get set }
    /// Selects the right-clicked item when it isn't part of the selection yet, as Finder does.
    func prepareForContextMenu()
    /// Files dropped on the view: the dropped URLs, the folder they go into, and whether Option asked for a copy.
    var onDrop: (([URL], URL, Bool) -> Void)? { get set }
    /// The user pressed Return: rename.
    var onRename: (() -> Void)? { get set }
}

/// Keys every file view handles the same way: Cmd+Down and Cmd+O open,
/// Space toggles Quick Look.
@MainActor
enum FileViewKeys {
    enum Action { case open, quickLook, rename }

    static func action(for event: NSEvent) -> Action? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command, event.specialKey == .downArrow { return .open }
        if flags.isEmpty, event.charactersIgnoringModifiers == " " { return .quickLook }
        if flags.isEmpty, event.specialKey == .carriageReturn || event.specialKey == .enter { return .rename }
        return nil
    }

    /// The pasteboard types file views accept in a drop.
    static let dropTypes: [NSPasteboard.PasteboardType] = [.fileURL]

    static func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Copy when Option is held or the files come from another disk; move otherwise.
    static func dropOperation(_ info: NSDraggingInfo, into folder: URL) -> NSDragOperation {
        let urls = droppedURLs(info)
        guard !urls.isEmpty, !urls.contains(where: { $0 == folder || folder.path.hasPrefix($0.path + "/") }) else { return [] }
        if NSEvent.modifierFlags.contains(.option) { return .copy }
        let volume = { (url: URL) in try? url.resourceValues(forKeys: [.volumeURLKey]).volume }
        return urls.allSatisfy { volume($0) == volume(folder) } ? .move : .copy
    }
}
