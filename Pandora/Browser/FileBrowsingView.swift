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
}

/// Keys every file view handles the same way: Cmd+Down and Cmd+O open,
/// Space toggles Quick Look.
@MainActor
enum FileViewKeys {
    enum Action { case open, quickLook }

    static func action(for event: NSEvent) -> Action? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command, event.specialKey == .downArrow { return .open }
        if flags.isEmpty, event.charactersIgnoringModifiers == " " { return .quickLook }
        return nil
    }
}
