#if PANDORA_DEV
import AppKit
import os

/// Development-only remote control, so Claude can drive Pandora Dev from the
/// terminal and look at the result without screen-recording access.
///
/// Post a distributed notification named `com.antonispanos.pandora.dev.hook`
/// whose object is one of:
///   "command:<id>"     runs a command from Commands.all in the key window
///   "go:<path>"        goes to a typed path in the key window
///   "snapshot:<name>"  renders the key window (or sheet, or palette) into <container tmp>/<name>.png
///   "appearance:dark" / "appearance:light" / "appearance:system"
///   "sidebar:<title>"  opens the sidebar item with that title
///   "activate"         brings Pandora Dev to the front (the palette needs focus)
///   "dismiss"          closes any open sheet (alerts)
///   "state"            logs the key window's location, items and the sidebar
///
/// For example: `swift scripts/devhook.swift command:viewList`.
/// Snapshots go to the app's own sandbox container, never to the test disk
/// or anywhere else, and none of this is compiled into the real app.
@MainActor
enum DevHooks {
    private static let logger = Logger(subsystem: "com.antonispanos.pandora", category: "DevHooks")
    private static var observer: NSObjectProtocol?

    static func install() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.antonispanos.pandora.dev.hook"), object: nil, queue: .main
        ) { notification in
            let request = notification.object as? String ?? ""
            MainActor.assumeIsolated { handle(request) }
        }
    }

    private static func handle(_ request: String) {
        let (verb, argument) = split(request)
        // The key window may be a sheet or the command palette; use the browser behind it.
        let controller = ([NSApp.keyWindow?.sheetParent, NSApp.keyWindow?.parent, NSApp.keyWindow, NSApp.mainWindow] + NSApp.orderedWindows)
            .lazy.compactMap { $0?.windowController as? BrowserWindowController }.first
        logger.notice("Hook: \(request, privacy: .public)")
        switch verb {
        case "command":
            guard let controller, let command = Commands.command(id: argument) else { return }
            command.run(controller)
        case "go":
            controller?.goToTypedPath(argument)
        case "snapshot":
            guard let main = controller?.window else { return }
            // Prefer what sits on top of the browser: an alert sheet or the palette.
            snapshot(main.attachedSheet ?? main.childWindows?.first(where: \.isVisible) ?? main, name: argument)
        case "sidebar":
            if let item = SidebarStore.shared.allItems.first(where: { $0.title == argument }), item.isEnabled {
                controller?.model.navigate(to: item.location)
            }
        case "activate":
            NSApp.activate()
        case "dismiss":
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
        case "appearance":
            NSApp.appearance = argument == "dark" ? NSAppearance(named: .darkAqua)
                : argument == "light" ? NSAppearance(named: .aqua) : nil
        case "state":
            if let controller {
                let model = controller.model
                logger.notice("State: \(model.location.title, privacy: .public), \(model.items.count) items, mode \(model.viewMode.rawValue, privacy: .public), sort \(model.sort.key.rawValue, privacy: .public), selected \(controller.selectedItems.map(\.name).joined(separator: ","), privacy: .public), tabs \(controller.window?.tabbedWindows?.count ?? 1)")
            }
            for item in SidebarStore.shared.allItems {
                logger.notice("Sidebar: \(item.title, privacy: .public) [\(item.isEnabled ? "on" : "off", privacy: .public)] \(item.subtitle ?? "", privacy: .public)")
            }
        default:
            logger.error("Unknown hook \(request, privacy: .public)")
        }
    }

    private static func split(_ request: String) -> (String, String) {
        guard let colon = request.firstIndex(of: ":") else { return (request, "") }
        return (String(request[..<colon]), String(request[request.index(after: colon)...]))
    }

    private static func snapshot(_ window: NSWindow, name: String) {
        // The frame view includes the title bar and toolbar.
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name + ".png")
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: file)
            logger.notice("Snapshot written to \(file.path, privacy: .public)")
        } catch {
            logger.error("Snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
