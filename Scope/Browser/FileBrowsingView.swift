import AppKit
import ScopeEngine

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
    /// Other keys from Settings > Shortcuts: back, forward, reload, trash.
    var onShortcut: ((FileViewKeys.Action) -> Void)? { get set }
}

/// Keys every file view handles the same way: Cmd+Down and Cmd+O open,
/// Space toggles Quick Look.
@MainActor
enum FileViewKeys {
    enum Action { case open, quickLook, rename, back, forward, reload, trash }

    /// Finder's keys, plus the alternatives switched on in Settings > Shortcuts.
    static func action(for event: NSEvent) -> Action? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let settings = AppSettings.shared
        if flags == .command, event.specialKey == .downArrow { return .open }
        if flags.isEmpty, event.charactersIgnoringModifiers == " " { return .quickLook }
        if flags.isEmpty, event.specialKey == .carriageReturn || event.specialKey == .enter {
            return settings.returnOpens ? .open : .rename
        }
        if flags.isEmpty, event.specialKey == .f2, settings.f2Renames { return .rename }
        if flags.isEmpty, event.specialKey == .f5, settings.f5Reloads { return .reload }
        if flags == .option, settings.optionArrowsNavigate {
            if event.specialKey == .leftArrow { return .back }
            if event.specialKey == .rightArrow { return .forward }
        }
        if flags.isEmpty, event.specialKey == .delete || event.specialKey == .backspace {
            switch settings.deleteKey {
            case .nothing: return nil
            case .goBack: return .back
            // A held-down Delete must not trash item after item.
            case .moveToTrash: return event.isARepeat ? nil : .trash
            }
        }
        return nil
    }

    /// Arrow keys with nothing selected: the event should select the first item.
    static func isArrowWithoutSelection(_ event: NSEvent, hasSelection: Bool) -> Bool {
        guard !hasSelection else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return flags.isEmpty && [.upArrow, .downArrow, .leftArrow, .rightArrow].contains(event.specialKey)
    }

    /// The pasteboard types file views accept in a drop.
    static let dropTypes: [NSPasteboard.PasteboardType] = [.fileURL]

    static func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls =
            info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [NSURL] ?? []
        // Drags carry file reference URLs (file:///.file/id=…); turn them into paths.
        return urls.compactMap { ($0.filePathURL ?? $0 as URL).standardizedFileURL }
    }

    /// Copy when Option is held or the files come from another disk; move otherwise.
    /// This runs on every mouse move of a drag, so it must not touch the disk:
    /// the disks come from the kernel's mount table. The drop itself checks
    /// them exactly, off the main thread, and copies when the badge said copy.
    static func dropOperation(_ info: NSDraggingInfo, into folder: URL) -> NSDragOperation {
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        return dropOperation(droppedURLs(info), into: folder, optionHeld: optionHeld, mounts: MountTable())
    }

    /// The decision itself, apart from the drag, so tests can call it.
    static func dropOperation(_ urls: [URL], into folder: URL, optionHeld: Bool, mounts: MountTable)
        -> NSDragOperation
    {
        guard !urls.isEmpty, !urls.contains(where: { $0 == folder || folder.path.hasPrefix($0.path + "/") }) else {
            return []
        }
        // Dropping items on the folder they're already in does nothing.
        if urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL }) {
            return []
        }
        if optionHeld { return .copy }
        return mounts.seemOnSameDisk(urls, as: folder) ? .move : .copy
    }
}
