import AppKit
import ScopeEngine

/// Builds the right-click menu each time it opens, from the selection: open,
/// Open With, Quick Look, the file operations, copy and paste, tags.
@MainActor
final class ContextMenuBuilder: NSObject, NSMenuDelegate {
    weak var controller: BrowserWindowController?
    /// Counts menu builds, so a late tag or app lookup can't land in a newer menu.
    private var generation = 0

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        generation += 1
        guard let controller else { return }
        controller.prepareForContextMenu()
        let selection = controller.selectedItems

        func add(_ id: String, _ title: String? = nil) {
            guard let command = Commands.command(id: id), command.isEnabled(controller) else { return }
            let item = NSMenuItem(
                title: title ?? command.title, action: #selector(BrowserWindowController.runCommand(_:)),
                keyEquivalent: "")
            item.representedObject = id
            menu.addItem(item)
        }
        /// A submenu of commands, with a check on the current choice.
        func submenu(_ title: String, _ ids: [String]) {
            let sub = NSMenu(title: title)
            for id in ids {
                guard let command = Commands.command(id: id) else { continue }
                if id == "sort.ascending" { sub.addItem(.separator()) }
                let item = NSMenuItem(
                    title: command.title, action: #selector(BrowserWindowController.runCommand(_:)), keyEquivalent: "")
                item.representedObject = id
                item.state = command.isChecked?(controller) == true ? .on : .off
                sub.addItem(item)
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }
        let sortIDs = [
            "sort.name", "sort.kind", "sort.added", "sort.modified", "sort.created", "sort.size",
            "sort.ascending", "sort.descending",
        ]
        let viewIDs = ViewMode.allCases.map { "view." + $0.rawValue }
        func separator() {
            if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
        }

        if selection.isEmpty {
            add("newFolder")
            separator()
            add("paste")
            add("moveHere")
            separator()
            add("getInfo", "Get Info for This Folder")
            add("copyPath", "Copy Path of This Folder")
            add("addToSidebar")
            separator()
            submenu("Sort By", sortIDs)
            submenu("View", viewIDs)
            add("toggleHidden")
        } else {
            add("open")
            if let item = controller.openWithItem { addOpenWith(for: item, to: menu, controller: controller) }
            add("openInNewTab")
            add("openInSplit")
            add("quickLook")
            add("getInfo")
            add("print")
            separator()
            add("rename")
            add("duplicate")
            add(
                "compress",
                selection.count == 1 ? "Compress “\(selection[0].name)”" : "Compress \(selection.count) Items")
            add("extract")
            add("mount")
            add("mountReadOnly")
            add("eject")
            add("trash")
            separator()
            add("cut", selection.count == 1 ? "Cut “\(selection[0].name)”" : "Cut \(selection.count) Items")
            add("copy", selection.count == 1 ? "Copy “\(selection[0].name)”" : "Copy \(selection.count) Items")
            add("copyPath")
            add("addToSidebar")
            separator()
            submenu("Sort By", sortIDs)
            if selection.count == 1 { addTags(of: selection[0], to: menu, engine: controller.model.engine) }
        }
    }

    /// Open With, filled in when the apps arrive: finding the apps that open
    /// a file reads the disk, so it happens in the background. The line goes
    /// away again when no app can open the file.
    private func addOpenWith(for item: FileItem, to menu: NSMenu, controller: BrowserWindowController) {
        let line = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let apps = NSMenu(title: "Open With")
        let waiting = NSMenuItem(title: "Finding Apps…", action: nil, keyEquivalent: "")
        waiting.isEnabled = false
        apps.addItem(waiting)
        line.submenu = apps
        menu.addItem(line)
        let build = generation
        let url = item.url
        let pathGuard = controller.model.engine.pathGuard
        Task { [weak controller] in
            let found = await BrowserWindowController.openWithApps(for: url, pathGuard: pathGuard)
            guard build == generation, let controller else { return }
            guard !found.isEmpty else {
                if menu.index(of: line) >= 0 { menu.removeItem(line) }
                return
            }
            apps.removeAllItems()
            for app in found { apps.addItem(controller.openWithEntry(for: app)) }
        }
    }

    /// The item's tags, read-only for now (editing tags comes in phase 1).
    /// Reading them is disk work, so it happens in the background and the
    /// line is added to the open menu when they arrive; an item without tags
    /// gets none.
    private func addTags(of item: FileItem, to menu: NSMenu, engine: FileEngine) {
        let build = generation
        let url = item.url
        Task {
            guard let tags = try? await engine.tags(for: url), !tags.isEmpty, build == generation else { return }
            if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
            let line = NSMenuItem(title: "Tags: " + tags.joined(separator: ", "), action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }
    }
}
