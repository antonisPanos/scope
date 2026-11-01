import AppKit
import PandoraEngine

/// Every action a browser window offers, in one list. The menu bar and the
/// command palette are both built from it, so a command and its Finder
/// shortcut are defined once.
@MainActor
struct Command: Identifiable {
    enum Menu { case file, view, sortBy, go }

    let id: String
    let title: String
    let menu: Menu
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let run: @MainActor (BrowserWindowController) -> Void
    var isEnabled: @MainActor (BrowserWindowController) -> Bool = { _ in true }
    var isChecked: (@MainActor (BrowserWindowController) -> Bool)?
    /// A separator goes above this command in its menu.
    var startsGroup = false

    /// The shortcut as the menu shows it, such as ⇧⌘G.
    var shortcutText: String {
        guard !key.isEmpty else { return "" }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case Self.upArrow: text += "↑"
        case Self.downArrow: text += "↓"
        default: text += key.uppercased()
        }
        return text
    }

    static let upArrow = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
    static let downArrow = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
}

@MainActor
enum Commands {
    static let all: [Command] = file + view + sortBy + go

    static func command(id: String) -> Command? {
        all.first { $0.id == id }
    }

    private static let file: [Command] = [
        Command(id: "newTab", title: "New Tab", menu: .file, key: "t", modifiers: .command,
                run: { $0.newWindowForTab(nil) }),
        Command(id: "open", title: "Open", menu: .file, key: "o", modifiers: .command,
                run: { $0.openSelection() }, isEnabled: { !$0.selectedItems.isEmpty }, startsGroup: true),
        Command(id: "addToSidebar", title: "Add to Sidebar", menu: .file, key: "t", modifiers: [.control, .command],
                run: { $0.addSelectionToSidebar() }, isEnabled: { $0.folderToAddToSidebar != nil }, startsGroup: true),
        Command(id: "eject", title: "Eject", menu: .file, key: "e", modifiers: .command,
                run: { $0.ejectSelectedVolume() }, isEnabled: { $0.volumeToEject != nil }),
    ]

    private static let view: [Command] = [
        Command(id: "viewDetails", title: "as Details", menu: .view, key: "2", modifiers: .command,
                run: { $0.model.viewMode = .details }, isChecked: { $0.model.viewMode == .details }),
        Command(id: "viewList", title: "as List", menu: .view, key: "5", modifiers: .command,
                run: { $0.model.viewMode = .list }, isChecked: { $0.model.viewMode == .list }),
        Command(id: "toggleHidden", title: "Show Hidden Files", menu: .view, key: ".", modifiers: [.shift, .command],
                run: { _ in AppSettings.shared.showHiddenFiles.toggle() },
                isChecked: { _ in AppSettings.shared.showHiddenFiles }, startsGroup: true),
        Command(id: "togglePathBar", title: "Show Path Bar", menu: .view, key: "p", modifiers: [.option, .command],
                run: { $0.togglePathBar() }, isChecked: { $0.isPathBarVisible }),
        Command(id: "toggleStatusBar", title: "Show Status Bar", menu: .view, key: "/", modifiers: .command,
                run: { $0.toggleStatusBar() }, isChecked: { $0.isStatusBarVisible }),
        Command(id: "toggleSidebar", title: "Show Sidebar", menu: .view, key: "s", modifiers: [.control, .command],
                run: { $0.toggleSidebar() }, isChecked: { $0.isSidebarVisible }),
        Command(id: "reload", title: "Reload", menu: .view, key: "r", modifiers: .command,
                run: { $0.model.reload() }, startsGroup: true),
    ]

    private static let sortBy: [Command] = [
        sort("Name", .name, "1"), sort("Kind", .kind, "2"), sort("Date Added", .added, "4"),
        sort("Date Modified", .modified, "5"), sort("Date Created", .created, "6"), sort("Size", .size, "7"),
    ]

    private static func sort(_ title: String, _ key: FileSort.Key, _ shortcut: String) -> Command {
        Command(id: "sort." + key.rawValue, title: title, menu: .sortBy, key: shortcut, modifiers: [.control, .option, .command],
                run: { controller in
                    let ascending = key == .name || key == .kind
                    controller.model.sort = FileSort(key: key, ascending: ascending)
                },
                isChecked: { $0.model.sort.key == key })
    }

    private static let go: [Command] = [
        Command(id: "back", title: "Back", menu: .go, key: "[", modifiers: .command,
                run: { $0.model.goBack() }, isEnabled: { $0.model.canGoBack }),
        Command(id: "forward", title: "Forward", menu: .go, key: "]", modifiers: .command,
                run: { $0.model.goForward() }, isEnabled: { $0.model.canGoForward }),
        Command(id: "enclosing", title: "Enclosing Folder", menu: .go, key: Command.upArrow, modifiers: .command,
                run: { $0.model.goUp() }, isEnabled: { $0.model.canGoUp }),
        Command(id: "goRecents", title: "Recents", menu: .go, key: "f", modifiers: [.shift, .command],
                run: { $0.model.navigate(to: .recents) }, startsGroup: true),
        place("Documents", "goDocuments", "o", [.shift, .command]) { $0.appendingPathComponent("Documents") },
        place("Desktop", "goDesktop", "d", [.shift, .command]) { $0.appendingPathComponent("Desktop") },
        place("Downloads", "goDownloads", "l", [.option, .command]) { $0.appendingPathComponent("Downloads") },
        place("Home", "goHome", "h", [.shift, .command]) { $0 },
        place("Computer", "goComputer", "c", [.shift, .command]) { _ in URL(fileURLWithPath: "/") },
        place("Applications", "goApplications", "a", [.shift, .command]) { _ in URL(fileURLWithPath: "/Applications") },
        Command(id: "goTestDisk", title: "Test Disk", menu: .go, key: "", modifiers: [],
                run: { $0.model.navigate(to: .folder(BuildIdentity.testDiskRoots[0])) },
                isEnabled: { _ in BuildIdentity.current.isDevelopment }),
        Command(id: "goToFolder", title: "Go to Folder…", menu: .go, key: "g", modifiers: [.shift, .command],
                run: { $0.beginTypingPath() }, startsGroup: true),
        Command(id: "editPath", title: "Edit Path", menu: .go, key: "l", modifiers: .command,
                run: { $0.beginTypingPath() }),
        Command(id: "palette", title: "Command Palette…", menu: .go, key: "k", modifiers: .command,
                run: { $0.showCommandPalette() }, startsGroup: true),
    ]

    /// A standard place; disabled when the path guard refuses it (outside
    /// the test disks in development builds).
    private static func place(_ title: String, _ id: String, _ key: String, _ modifiers: NSEvent.ModifierFlags,
                              _ url: @escaping @Sendable (URL) -> URL) -> Command {
        Command(id: id, title: title, menu: .go, key: key, modifiers: modifiers,
                run: { $0.model.navigate(to: .folder(url(BuildIdentity.realHome))) },
                isEnabled: { $0.model.engine.pathGuard.permits(url(BuildIdentity.realHome)) })
    }
}
