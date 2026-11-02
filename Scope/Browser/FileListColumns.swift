import AppKit
import ScopeEngine

/// The file list's columns, and the header menu that shows or hides them.
extension FileListViewController {
    enum Column: String, CaseIterable {
        case name, location, modified, created, added, size, kind, tags

        var title: String {
            switch self {
            case .name: "Name"
            case .location: "Where"
            case .modified: "Date Modified"
            case .created: "Date Created"
            case .added: "Date Added"
            case .size: "Size"
            case .kind: "Kind"
            case .tags: "Tags"
            }
        }

        var sortKey: FileSort.Key? {
            switch self {
            case .name: .name
            case .modified: .modified
            case .created: .created
            case .added: .added
            case .size: .size
            case .kind: .kind
            case .tags, .location: nil
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 220
            case .modified, .created, .added: 150
            case .size: 70
            case .kind: 130
            case .tags: 120
            case .location: 200
            }
        }

        var hiddenByDefault: Bool { self == .created || self == .added || self == .tags || self == .location }
        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
    }

    // MARK: - Header menu (show or hide columns)

    func hiddenKey(_ column: Column) -> String { "FileListColumnHidden.\(column.rawValue)" }

    func makeHeaderMenu() -> NSMenu {
        let menu = NSMenu()
        for column in Column.allCases where column != .name && column != .location {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            menu.addItem(item)
        }
        menu.delegate = self
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = Column(rawValue: raw),
            let tableColumn = outlineView.tableColumn(withIdentifier: column.identifier)
        else { return }
        tableColumn.isHidden.toggle()
        UserDefaults.standard.set(tableColumn.isHidden, forKey: hiddenKey(column))
        outlineView.reloadData()
    }
}

extension FileListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let raw = item.representedObject as? String, let column = Column(rawValue: raw) else { continue }
            item.state = outlineView.tableColumn(withIdentifier: column.identifier)?.isHidden == false ? .on : .off
        }
    }
}
