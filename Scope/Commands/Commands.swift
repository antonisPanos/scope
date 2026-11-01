import AppKit
import ScopeEngine

/// Every action a browser window offers, in one list. The menu bar and the
/// command palette are both built from it, so a command and its Finder
/// shortcut are defined once.
@MainActor
struct Command: Identifiable {
    /// `contextOnly` commands appear in the right-click menu and the palette,
    /// not the menu bar (where AppKit's own Copy and Paste items live).
    enum Menu { case file, edit, view, sortBy, go, contextOnly }

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
    /// Held-down keys repeat; destructive commands ignore the repeats.
    var ignoresKeyRepeat = false

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
        case Self.leftArrow: text += "←"
        case Self.rightArrow: text += "→"
        case "-": text += "−"
        case Self.backspace: text += "⌫"
        default: text += key.uppercased()
        }
        return text
    }

    static let upArrow = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
    static let downArrow = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
    static let leftArrow = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    static let rightArrow = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
    static let backspace = String(Character(UnicodeScalar(NSBackspaceCharacter)!))
}

@MainActor
enum Commands {
    static let all: [Command] = file + edit + viewModes + view + sortBy + go

    /// as Icons (Cmd+1), as Details (Cmd+2), as Columns (Cmd+3), as Gallery (Cmd+4), as List (Cmd+5).
    private static let viewModes: [Command] = ViewMode.allCases.map { mode in
        Command(id: "view." + mode.rawValue, title: "as \(mode.title)", menu: .view, key: mode.shortcut, modifiers: .command,
                run: { $0.model.viewMode = mode }, isChecked: { $0.model.viewMode == mode })
    }

    static func command(id: String) -> Command? {
        all.first { $0.id == id }
    }

    private static let file: [Command] = [
        Command(id: "newTab", title: "New Tab", menu: .file, key: "t", modifiers: .command,
                run: { $0.newWindowForTab(nil) }),
        Command(id: "newFolder", title: "New Folder…", menu: .file, key: "n", modifiers: [.shift, .command],
                run: { $0.newFolder() }, isEnabled: { $0.currentFolder != nil && $0.allowsWrites }),
        Command(id: "open", title: "Open", menu: .file, key: "o", modifiers: .command,
                run: { $0.openSelection() }, isEnabled: { !$0.selectedItems.isEmpty }, startsGroup: true),
        Command(id: "getInfo", title: "Get Info", menu: .file, key: "i", modifiers: .command,
                run: { $0.showInfo() }, isEnabled: { !$0.selectedItems.isEmpty || $0.currentFolder != nil }),
        Command(id: "rename", title: "Rename…", menu: .file, key: "", modifiers: [],
                run: { $0.renameSelection() }, isEnabled: { $0.selectedItems.count == 1 && $0.allowsWrites }, startsGroup: true),
        Command(id: "duplicate", title: "Duplicate", menu: .file, key: "d", modifiers: .command,
                run: { $0.duplicateSelection() }, isEnabled: { !$0.selectedItems.isEmpty && $0.allowsWrites }, ignoresKeyRepeat: true),
        Command(id: "compress", title: "Compress", menu: .file, key: "", modifiers: [],
                run: { $0.compressSelection() }, isEnabled: { !$0.selectedItems.isEmpty && $0.allowsWrites }),
        Command(id: "extract", title: "Extract", menu: .file, key: "", modifiers: [],
                run: { $0.extractSelection() }, isEnabled: { $0.archiveToExtract != nil && $0.allowsWrites }),
        Command(id: "mount", title: "Mount Disk Image", menu: .file, key: "", modifiers: [],
                run: { $0.mountSelection() }, isEnabled: { $0.imageToMount != nil }),
        Command(id: "mountReadOnly", title: "Mount Read-Only", menu: .file, key: "", modifiers: [],
                run: { $0.mountSelection(readOnly: true) }, isEnabled: { $0.imageToMount != nil }),
        Command(id: "trash", title: "Move to Trash", menu: .file, key: Command.backspace, modifiers: .command,
                run: { $0.trashSelection() }, isEnabled: { !$0.selectedItems.isEmpty && $0.allowsWrites },
                startsGroup: true, ignoresKeyRepeat: true),
        Command(id: "copyToOther", title: "Copy to Other Side", menu: .file, key: "c", modifiers: [.control, .command],
                run: { $0.transferToOtherPane(move: false) },
                isEnabled: { !$0.selectedItems.isEmpty && $0.otherPaneFolder != nil && $0.allowsWrites }, startsGroup: true,
                ignoresKeyRepeat: true),
        Command(id: "moveToOther", title: "Move to Other Side", menu: .file, key: "m", modifiers: [.control, .command],
                run: { $0.transferToOtherPane(move: true) },
                isEnabled: { !$0.selectedItems.isEmpty && $0.otherPaneFolder != nil && $0.allowsWrites }, ignoresKeyRepeat: true),
        Command(id: "addToSidebar", title: "Add to Sidebar", menu: .file, key: "t", modifiers: [.control, .command],
                run: { $0.addSelectionToSidebar() }, isEnabled: { $0.folderToAddToSidebar != nil }, startsGroup: true),
        Command(id: "eject", title: "Eject", menu: .file, key: "e", modifiers: .command,
                run: { $0.ejectSelectedVolume() }, isEnabled: { $0.volumeToEject != nil }),
    ]

    private static let edit: [Command] = [
        Command(id: "copy", title: "Copy", menu: .contextOnly, key: "", modifiers: [],
                run: { $0.copySelection() }, isEnabled: { !$0.selectedItems.isEmpty }),
        Command(id: "paste", title: "Paste Items", menu: .contextOnly, key: "", modifiers: [],
                run: { $0.paste(move: false) },
                isEnabled: { !$0.pasteboardFiles.isEmpty && $0.currentFolder != nil && $0.allowsWrites }, ignoresKeyRepeat: true),
        Command(id: "moveHere", title: "Move Item Here", menu: .edit, key: "v", modifiers: [.option, .command],
                run: { $0.paste(move: true) },
                isEnabled: { !$0.pasteboardFiles.isEmpty && $0.currentFolder != nil && $0.allowsWrites }, ignoresKeyRepeat: true),
        Command(id: "copyPath", title: "Copy Path", menu: .edit, key: "c", modifiers: [.option, .command],
                run: { $0.copyPathOfSelection() }),
    ]

    private static let view: [Command] = [
        Command(id: "biggerIcons", title: "Make Icons Bigger", menu: .view, key: "=", modifiers: .command,
                run: { _ in AppSettings.shared.iconSize *= 1.25 }, isEnabled: { $0.model.viewMode == .icons }, startsGroup: true),
        Command(id: "smallerIcons", title: "Make Icons Smaller", menu: .view, key: "-", modifiers: .command,
                run: { _ in AppSettings.shared.iconSize /= 1.25 }, isEnabled: { $0.model.viewMode == .icons }),
        Command(id: "quickLook", title: "Quick Look", menu: .view, key: "y", modifiers: .command,
                run: { $0.toggleQuickLook() }, isEnabled: { !$0.selectedItems.isEmpty }, startsGroup: true),
        Command(id: "togglePreview", title: "Show Preview", menu: .view, key: "p", modifiers: [.shift, .command],
                run: { $0.togglePreview() }, isChecked: { $0.isPreviewVisible }),
        Command(id: "toggleHidden", title: "Show Hidden Files", menu: .view, key: ".", modifiers: [.shift, .command],
                run: { _ in AppSettings.shared.showHiddenFiles.toggle() },
                isChecked: { _ in AppSettings.shared.showHiddenFiles }, startsGroup: true),
        Command(id: "togglePathBar", title: "Show Path Bar", menu: .view, key: "p", modifiers: [.option, .command],
                run: { $0.togglePathBar() }, isChecked: { $0.isPathBarVisible }),
        Command(id: "toggleStatusBar", title: "Show Status Bar", menu: .view, key: "/", modifiers: .command,
                run: { $0.toggleStatusBar() }, isChecked: { $0.isStatusBarVisible }),
        Command(id: "toggleSidebar", title: "Show Sidebar", menu: .view, key: "s", modifiers: [.control, .command],
                run: { $0.toggleSidebar() }, isChecked: { $0.isSidebarVisible }),
        Command(id: "toggleSplit", title: "Split View", menu: .view, key: "s", modifiers: [.shift, .command],
                run: { $0.toggleSplit() }, isChecked: { $0.isSplit }, startsGroup: true),
        Command(id: "openInNewTab", title: "Open in New Tab", menu: .view, key: "", modifiers: [],
                run: { $0.openSelectionInNewTab() }, isEnabled: { $0.folderForSplit != nil }),
        Command(id: "openInSplit", title: "Open in Split View", menu: .view, key: "", modifiers: [],
                run: { $0.openInSplit() }, isEnabled: { $0.folderForSplit != nil }),
        Command(id: "focusLeft", title: "Focus Left Side", menu: .view, key: Command.leftArrow, modifiers: [.option, .command],
                run: { $0.focusPane(0) }, isEnabled: { $0.isSplit }),
        Command(id: "focusRight", title: "Focus Right Side", menu: .view, key: Command.rightArrow, modifiers: [.option, .command],
                run: { $0.focusPane(1) }, isEnabled: { $0.isSplit }),
        Command(id: "toggleActivity", title: "Show Activity", menu: .view, key: "a", modifiers: [.option, .command],
                run: { $0.showActivity(!$0.isActivityVisible) }, isChecked: { $0.isActivityVisible }),
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
        Command(id: "find", title: "Find…", menu: .go, key: "f", modifiers: .command,
                run: { $0.beginSearch() }, isEnabled: { $0.model.location.searchRoot != nil }, startsGroup: true),
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
