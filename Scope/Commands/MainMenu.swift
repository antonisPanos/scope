import AppKit

/// The menu bar. Browser commands come from `Commands.all` and go to the key
/// window's controller through the responder chain; standard items (Edit,
/// Window) use AppKit's own actions so text fields and tabs work as usual.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let name = BuildIdentity.current.appName
        let main = NSMenu()

        let app = NSMenu(title: name)
        app.addItem(
            withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"
        )
        .keyEquivalentModifierMask = [.command, .option]
        app.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        addCommands(.file, to: file)
        file.addItem(.separator())
        file.addItem(
            withTitle: "Close Tab", action: #selector(BrowserWindowController.closeTabOrWindow(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        add(file, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(BrowserWindowController.undo(_:)), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        addCommands(.edit, to: edit)
        add(edit, to: main)

        let view = NSMenu(title: "View")
        addCommands(.view, to: view)
        let sortBy = NSMenu(title: "Sort By")
        addCommands(.sortBy, to: sortBy)
        view.addItem(.separator())
        view.addItem(withTitle: "Sort By", action: nil, keyEquivalent: "").submenu = sortBy
        view.addItem(.separator())
        view.addItem(withTitle: "Show Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "T")
        view.addItem(withTitle: "Show All Tabs", action: #selector(NSWindow.toggleTabOverview(_:)), keyEquivalent: "\\")
            .keyEquivalentModifierMask = [.shift, .command]
        view.addItem(
            withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"
        )
        .keyEquivalentModifierMask = [.control, .command]
        add(view, to: main)

        let go = NSMenu(title: "Go")
        addCommands(.go, to: go)
        add(go, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(
            withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "\t"
        )
        .keyEquivalentModifierMask = [.control, .shift]
        window.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "\t")
            .keyEquivalentModifierMask = .control
        window.addItem(
            withTitle: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        main.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
    }

    private static func addCommands(_ section: Command.Menu, to menu: NSMenu) {
        for command in Commands.all where command.menu == section {
            if command.startsGroup, !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(
                title: command.title,
                action: #selector(BrowserWindowController.runCommand(_:)),
                keyEquivalent: command.key)
            item.keyEquivalentModifierMask = command.modifiers
            item.representedObject = command.id
            menu.addItem(item)
        }
    }
}
