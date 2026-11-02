#if SCOPE_DEV
import AppKit
import os
import ScopeEngine

/// Development-only remote control, so Claude can drive Scope Dev from the
/// terminal and look at the result without screen-recording access.
///
/// Post a distributed notification named `com.antonispanos.scope.dev.hook`
/// whose object is one of:
///   "command:<id>"     runs a command from Commands.all in the key window
///   "go:<path>"        goes to a typed path in the key window
///   "snapshot:<name>"  renders the key window (or sheet, or palette) into <temporary folder>/<name>.png;
///                      names are A-Z, a-z, 0-9, - and _ only
///   "appearance:dark" / "appearance:light" / "appearance:system"
///   "sidebar:<title>"  opens the sidebar item with that title
///   "select:<names>"   selects items by name (comma separated) in the folder on screen
///   "press:<title>"    presses a button on an open sheet
///   "type:<text>"      puts text in the first text field of an open sheet (the Rename and New Folder name)
///   "cancel"           cancels the newest running operation, as its Cancel button does
///   "ops"              logs every operation in the activity list
///   "search:<mode>:<text>"  searches (mode: contains, glob, regex, contents)
///   "searchkind:<kind>" limits the search to one kind; "endsearch" ends it
///   "undo"             undoes the last operation
///   "activate"         brings Scope Dev to the front (the palette needs focus)
///   "dismiss"          closes any open sheet (alerts)
///   "state"            logs the key window's location, items, the sidebar and its selected item
///
/// For example: `swift scripts/devhook.swift command:viewList`.
/// Snapshots go to the temporary folder and nowhere else, and none of this is
/// compiled into the real app.
@MainActor
enum DevHooks {
    private static let logger = Logger(subsystem: "com.antonispanos.scope", category: "DevHooks")
    private static var observer: NSObjectProtocol?

    static func install() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.antonispanos.scope.dev.hook"), object: nil, queue: .main
        ) { notification in
            let request = notification.object as? String ?? ""
            MainActor.assumeIsolated { handle(request) }
        }
    }

    private static func handle(_ request: String) {
        let (verb, argument) = split(request)
        // The key window may be a sheet or the command palette; use the browser behind it.
        let controller =
            ([NSApp.keyWindow?.sheetParent, NSApp.keyWindow?.parent, NSApp.keyWindow, NSApp.mainWindow]
            + NSApp.orderedWindows)
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
        case "select":
            // "select:a.txt,b.txt" selects items by name in the folder on screen.
            let names = Set(argument.split(separator: ",").map(String.init))
            let urls = controller?.model.items.filter { names.contains($0.name) }.map(\.url) ?? []
            controller?.selectForHooks(urls)
        case "press":
            // Presses a button by title on any open sheet (an alert or the conflict dialog).
            for window in NSApp.windows {
                guard let sheet = window.attachedSheet else { continue }
                if let button = findButton(argument, in: sheet.contentView) { button.performClick(nil) }
            }
        case "ops":
            for snapshot in OperationsController.shared.snapshots {
                let progress = snapshot.progress
                logger.notice(
                    "Op: \(snapshot.title, privacy: .public) [\(String(describing: snapshot.state), privacy: .public)] \(progress.itemsDone)/\(progress.itemsTotal) items \(progress.bytesDone)/\(progress.bytesTotal) bytes speed \(Int(snapshot.speed ?? 0)) undo \(snapshot.canUndo) skipped \(snapshot.skippedEntries.count)"
                )
            }
        case "search":
            controller?.searchForHooks(argument)
        case "searchkind":
            // "searchkind:image" limits the current search to one kind.
            if let kind = SearchQuery.Kind(rawValue: argument) {
                controller?.searchSettingsForHooks.kinds = [kind]
                controller?.runSearch()
            }
        case "endsearch":
            controller?.endSearch()
        case "panes":
            controller?.logPanesForHooks()
        case "overlays":
            // Lists every view drawn over the focused path bar, front to back.
            guard let window = controller?.window, let frameView = window.contentView?.superview,
                let bar = controller?.pathBarForHooks
            else { return }
            let target = bar.convert(bar.bounds, to: nil)
            func walk(_ view: NSView, depth: Int) {
                let rect = view.convert(view.bounds, to: nil)
                if rect.intersects(target), !view.isHidden, view.alphaValue > 0 {
                    logger.notice(
                        "Overlay \(String(repeating: " ", count: depth), privacy: .public)\(String(describing: type(of: view)), privacy: .public) \(NSStringFromRect(rect), privacy: .public)"
                    )
                }
                for sub in view.subviews { walk(sub, depth: depth + 1) }
            }
            walk(frameView, depth: 0)
        case "zoom":
            controller?.window?.zoom(nil)
            if let window = controller?.window {
                logger.notice(
                    "Zoomed to \(NSStringFromRect(window.frame), privacy: .public), screen \(NSStringFromRect(window.screen?.visibleFrame ?? .zero), privacy: .public)"
                )
            }
        case "pathbar":
            guard let bar = controller?.pathBarForHooks else { return }
            func dump(_ view: NSView, _ depth: Int) {
                logger.notice(
                    "PB \(String(repeating: " ", count: depth), privacy: .public)\(String(describing: type(of: view)), privacy: .public) \(NSStringFromRect(view.frame), privacy: .public) hidden \(view.isHidden) alpha \(view.alphaValue) layer \(view.layer != nil) opacity \(view.layer?.opacity ?? -1)"
                )
                for sub in view.subviews { dump(sub, depth + 1) }
            }
            var ancestor: NSView? = bar
            while let current = ancestor {
                logger.notice(
                    "PB up \(String(describing: type(of: current)), privacy: .public) \(NSStringFromRect(current.frame), privacy: .public) bounds \(NSStringFromRect(current.bounds), privacy: .public) hidden \(current.isHidden) alpha \(current.alphaValue) opacity \(current.layer?.opacity ?? -1)"
                )
                ancestor = current.superview
            }
            dump(bar, 0)
            logger.notice(
                "PB window rect \(NSStringFromRect(bar.convert(bar.bounds, to: nil)), privacy: .public) visible \(NSStringFromRect(bar.visibleRect), privacy: .public)"
            )
        case "sidebarwidth":
            controller?.setSidebarWidthForHooks(CGFloat(Double(argument) ?? 200))
        case "resize":
            if let width = Double(argument), let window = controller?.window {
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true)
                logger.notice("Resized to \(window.frame.width) (asked \(width)), min \(window.minSize.width)")
            }
        case "type":
            for window in NSApp.windows {
                guard let sheet = window.attachedSheet else { continue }
                findField(in: sheet.contentView)?.stringValue = argument
            }
        case "cancel":
            if let running = OperationsController.shared.snapshots.last(where: \.isActive) {
                OperationsController.shared.cancel(running.id)
            }
        case "undo":
            controller?.undoLastOperation()
        case "activate":
            NSApp.activate()
        case "snapshotcontent":
            // The window's content view only, without the title bar and toolbar.
            if let view = controller?.window?.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            {
                view.cacheDisplay(in: view.bounds, to: rep)
                write(rep, name: argument)
            }
        case "dismiss":
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
        case "appearance":
            NSApp.appearance =
                argument == "dark"
                ? NSAppearance(named: .darkAqua)
                : argument == "light" ? NSAppearance(named: .aqua) : nil
        case "state":
            if let controller {
                let model = controller.model
                logger.notice(
                    "State: \(model.location.title, privacy: .public), \(model.items.count) items, mode \(model.viewMode.rawValue, privacy: .public), sort \(model.sort.key.rawValue, privacy: .public), selected \(controller.selectedItems.map(\.name).joined(separator: ","), privacy: .public), tabs \(controller.window?.tabbedWindows?.count ?? 1), activity drawer \(controller.isActivityVisible ? "shown" : "hidden", privacy: .public), app active \(NSApp.isActive), sidebar selected \(controller.sidebarSelectedIDForHooks ?? "none", privacy: .public)"
                )
            }
            for item in SidebarStore.shared.allItems {
                logger.notice(
                    "Sidebar: \(item.title, privacy: .public) [\(item.isEnabled ? "on" : "off", privacy: .public)] \(item.subtitle ?? "", privacy: .public)"
                )
            }
        default:
            logger.error("Unknown hook \(request, privacy: .public)")
        }
    }

    private static func findButton(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let found = findButton(title, in: subview) { return found }
        }
        return nil
    }

    private static func findField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let found = findField(in: subview) { return found }
        }
        return nil
    }

    private static func split(_ request: String) -> (String, String) {
        guard let colon = request.firstIndex(of: ":") else { return (request, "") }
        return (String(request[..<colon]), String(request[request.index(after: colon)...]))
    }

    private static func snapshot(_ window: NSWindow, name: String) {
        // The frame view includes the title bar and toolbar.
        guard let view = window.contentView?.superview ?? window.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        write(rep, name: name)
    }

    /// Whether `name` can name a snapshot: letters, digits, `-` and `_`
    /// only, so it can't step out of the temporary folder with `../` or a
    /// slash. Any local process can post these hooks.
    static func isValidSnapshotName(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Writes a snapshot as `<temporary folder>/<name>.png`. Taking the same
    /// snapshot again replaces the earlier one, which only ever lives there.
    private static func write(_ rep: NSBitmapImageRep, name: String) {
        guard isValidSnapshotName(name) else {
            logger.error("Snapshot refused: \(name, privacy: .public) isn't a plain name (A-Z, 0-9, - and _)")
            return
        }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name + ".png")
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: file, options: .atomic)
            logger.notice("Snapshot written to \(file.path, privacy: .public)")
        } catch {
            logger.error("Snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
