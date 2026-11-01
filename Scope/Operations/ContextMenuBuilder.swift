import AppKit
import ScopeEngine

/// Builds the right-click menu each time it opens, from the selection: open,
/// Open With, Quick Look, the file operations, copy and paste, tags.
@MainActor
final class ContextMenuBuilder: NSObject, NSMenuDelegate {
    weak var controller: BrowserWindowController?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller else { return }
        controller.prepareForContextMenu()
        let selection = controller.selectedItems

        func add(_ id: String, _ title: String? = nil) {
            guard let command = Commands.command(id: id), command.isEnabled(controller) else { return }
            let item = NSMenuItem(title: title ?? command.title, action: #selector(BrowserWindowController.runCommand(_:)),
                                  keyEquivalent: "")
            item.representedObject = id
            menu.addItem(item)
        }
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
            add("toggleHidden")
        } else {
            add("open")
            if let openWith = controller.openWithMenu() {
                let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                item.submenu = openWith
                menu.addItem(item)
            }
            add("openInNewTab")
            add("openInSplit")
            add("quickLook")
            add("getInfo")
            separator()
            add("rename")
            add("duplicate")
            add("compress", selection.count == 1 ? "Compress “\(selection[0].name)”" : "Compress \(selection.count) Items")
            add("extract")
            add("mount")
            add("mountReadOnly")
            add("eject")
            add("trash")
            separator()
            add("copy", selection.count == 1 ? "Copy “\(selection[0].name)”" : "Copy \(selection.count) Items")
            add("copyPath")
            add("addToSidebar")
            if let tags = controller.tagsMenu(for: selection) {
                separator()
                menu.addItem(tags)
            }
        }
    }
}

extension BrowserWindowController {
    /// The selection's tags, read-only for now (editing tags comes in phase 1).
    func tagsMenu(for selection: [FileItem]) -> NSMenuItem? {
        guard selection.count == 1, let url = selection.first?.url,
              let tags = try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames, !tags.isEmpty else { return nil }
        let item = NSMenuItem(title: "Tags: " + tags.joined(separator: ", "), action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
