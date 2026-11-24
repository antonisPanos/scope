import AppKit
import ScopeEngine

/// Builds the right-click menu each time it opens, from the selection: open,
/// Open With, Quick Look, the file operations, copy and paste, tags.
@MainActor
final class ContextMenuBuilder: NSObject, NSMenuDelegate {
    weak var controller: BrowserWindowController?
    /// Counts menu builds, so a late tag or app lookup can't land in a newer menu.
    private var generation = 0
    private var tagTask: Task<Void, Never>?
    private var openWithTask: Task<Void, Never>?

    func makeMenu(for tab: BrowserViewController) -> NSMenu {
        let menu = BrowserContextMenu(tab: tab)
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        generation += 1
        tagTask?.cancel()
        openWithTask?.cancel()
        guard let controller, let tab = (menu as? BrowserContextMenu)?.tab,
            controller.prepareForContextMenu(in: tab)
        else { return }
        let selection = tab.fileView.selectedItems

        func add(_ id: String, _ title: String? = nil) {
            guard let command = Commands.command(id: id), command.isEnabled(controller) else { return }
            let item = NSMenuItem(
                title: title ?? command.title, action: #selector(BrowserWindowController.runCommand(_:)),
                keyEquivalent: "")
            item.representedObject = id
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
            if let folder = tab.model.location.folderURL {
                addOpenWith(for: folder, isFolder: true, to: menu, controller: controller)
            }
            add("getInfo", "Get Info for This Folder")
            add("copyPath", "Copy Path of This Folder")
            add("addToSidebar")
            separator()
            addSubmenu("Sort By", commands: sortIDs, to: menu, controller: controller)
            addSubmenu("View", commands: viewIDs, to: menu, controller: controller)
            add("toggleHidden")
        } else {
            add("open")
            if selection.count == 1, let item = selection.first {
                addOpenWith(for: item.url, isFolder: item.isBrowsableFolder, to: menu, controller: controller)
            }
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
            add("deleteImmediately")
            separator()
            add("cut", selection.count == 1 ? "Cut “\(selection[0].name)”" : "Cut \(selection.count) Items")
            add("copy", selection.count == 1 ? "Copy “\(selection[0].name)”" : "Copy \(selection.count) Items")
            add("copyPath")
            add("addToSidebar")
            separator()
            addSubmenu("Sort By", commands: sortIDs, to: menu, controller: controller)
            if controller.allowsWrites {
                addTagRow(for: selection, to: menu, controller: controller)
            } else if selection.count == 1 {
                addTags(of: selection[0], to: menu, engine: controller.model.engine)
            }
        }
    }

    /// Adds a submenu of commands with a check on the current choice.
    private func addSubmenu(_ title: String, commands: [String], to menu: NSMenu, controller: BrowserWindowController) {
        let submenu = NSMenu(title: title)
        for id in commands {
            guard let command = Commands.command(id: id) else { continue }
            if id == "sort.ascending" { submenu.addItem(.separator()) }
            let item = NSMenuItem(
                title: command.title, action: #selector(BrowserWindowController.runCommand(_:)), keyEquivalent: "")
            item.representedObject = id
            item.state = command.isChecked?(controller) == true ? .on : .off
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    /// Finds apps in the background and removes the submenu if none are available.
    private func addOpenWith(for url: URL, isFolder: Bool, to menu: NSMenu, controller: BrowserWindowController) {
        let line = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let apps = NSMenu(title: "Open With")
        let waiting = NSMenuItem(title: "Finding Apps…", action: nil, keyEquivalent: "")
        waiting.isEnabled = false
        apps.addItem(waiting)
        line.submenu = apps
        menu.addItem(line)
        let build = generation
        let engine = controller.model.engine
        openWithTask = Task { [weak self, weak controller] in
            let found = await BrowserWindowController.openWithApps(for: url, isFolder: isFolder, engine: engine)
            guard !Task.isCancelled, self?.generation == build, let controller else { return }
            guard !found.isEmpty else {
                if menu.index(of: line) >= 0 { menu.removeItem(line) }
                return
            }
            apps.removeAllItems()
            for app in found { apps.addItem(controller.openWithEntry(for: app, opening: url, engine: engine)) }
        }
    }

    /// Finder's row of colour dots: a click adds that tag to every selected
    /// item, or takes it off when they all have it already. Which ones they
    /// have is read in the background and ticked when it arrives.
    private func addTagRow(for selection: [FileItem], to menu: NSMenu, controller: BrowserWindowController) {
        separator(in: menu)
        let urls = selection.map(\.url)
        let row = TagMenuView { [weak controller] tag, add in
            controller?.startOperation(.setTag(urls, tag: tag, applied: add))
        }
        let item = NSMenuItem()
        item.view = row
        menu.addItem(item)
        let build = generation
        let engine = controller.model.engine
        tagTask = Task { [weak self] in
            guard let common = try? await TagSelection.commonTags(in: urls, readTags: engine.tags),
                !Task.isCancelled, self?.generation == build
            else { return }
            row.showApplied(common)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        tagTask?.cancel()
        openWithTask?.cancel()
    }

    private func separator(in menu: NSMenu) {
        if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
    }

    /// The item's tags as a line, for builds that can't change files.
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

/// Identifies the pane that opened the menu even if another pane had focus.
@MainActor
private final class BrowserContextMenu: NSMenu {
    weak var tab: BrowserViewController?

    init(tab: BrowserViewController) {
        self.tab = tab
        super.init(title: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("BrowserContextMenu requires a browser tab") }
}
