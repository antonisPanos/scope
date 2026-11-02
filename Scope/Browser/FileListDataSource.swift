import AppKit
import ScopeEngine

/// Rows, cells, sorting and drag and drop for the file list. Expanded
/// folders list their children in the background.
extension FileListViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return roots.count }
        if node.children == nil { loadChildren(of: node) }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return roots[index] }
        return node.children?[index] ?? FileNode(item: node.item)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard model.viewMode == .details, let node = item as? FileNode else { return false }
        return node.item.isBrowsableFolder && !node.item.isSymbolicLink
    }

    private func loadChildren(of node: FileNode) {
        guard node.childrenListing == nil else { return }
        node.isLoadingChildren = true
        node.childrenListing = NestedFolderListing(url: node.item.url, model: model) { [weak self, weak node] sorted in
            guard let self, let node else { return }
            let old = Dictionary((node.children ?? []).map { ($0.item.url, $0) }, uniquingKeysWith: { a, _ in a })
            node.children = sorted.map { item in
                if let kept = old[item.url] {
                    kept.update(item)
                    return kept
                }
                return FileNode(item: item)
            }
            node.isLoadingChildren = false
            self.model.metadataDidChange()
            self.outlineView.reloadItem(node, reloadChildren: true)
            self.onSelectionChange?()
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        node.childrenListing = nil
        node.children = nil
        node.isLoadingChildren = false
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode, model.engine.pathGuard.permits(node.item.url) else { return nil }
        return node.item.url as NSURL
    }

    /// The folder a drop lands in: the folder row under the pointer, or the folder on screen.
    private func dropFolder(for item: Any?) -> URL? {
        if let node = item as? FileNode, node.item.isBrowsableFolder, !node.item.isSymbolicLink { return node.item.url }
        return model.location.folderURL
    }

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard model.engine.pathGuard.allowsWrites else { return [] }
        let target = (item as? FileNode).flatMap { $0.item.isBrowsableFolder ? $0 : nil }
        if target == nil {
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        } else {
            outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        guard let folder = dropFolder(for: target) else { return [] }
        return FileViewKeys.dropOperation(info, into: folder)
    }

    func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int
    ) -> Bool {
        guard let folder = dropFolder(for: item) else { return false }
        let urls = FileViewKeys.droppedURLs(info)
        let operation = FileViewKeys.dropOperation(info, into: folder)
        guard !urls.isEmpty, !operation.isEmpty else { return false }
        onDrop?(urls, folder, operation == .copy)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key,
            let sortKey = FileSort.Key(rawValue: key)
        else { return }
        model.sort = FileSort(key: sortKey, ascending: descriptor.ascending)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        PaletteRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode, let tableColumn,
            let column = Column(rawValue: tableColumn.identifier.rawValue)
        else { return nil }
        let file = node.item
        switch column {
        case .name:
            let cell =
                outlineView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? FileNameCell
                ?? FileNameCell()
            cell.identifier = tableColumn.identifier
            cell.configure(with: file)
            return cell
        case .tags:
            let cell = textCell(outlineView, tableColumn.identifier)
            cell.textField?.attributedStringValue = Self.tagText(tags(for: file) ?? [])
            return cell
        default:
            let cell = textCell(outlineView, tableColumn.identifier)
            cell.textField?.stringValue = Self.text(for: column, of: file)
            cell.textField?.alignment = column == .size ? .right : .left
            return cell
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any
    ) -> String? {
        guard tableColumn?.identifier == Column.name.identifier else { return nil }
        return (item as? FileNode)?.item.name
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    private func textCell(_ outlineView: NSOutlineView, _ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView
    {
        if let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView { return cell }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.textColor = Palette.secondaryText
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    static func text(for column: Column, of item: FileItem) -> String {
        switch column {
        case .name: item.name
        case .modified: DateText.format(item.modified)
        case .created: DateText.format(item.created)
        case .added: DateText.format(item.added)
        case .size: item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "--"
        case .kind: item.kind
        case .tags: ""
        case .location: PathBar.displayPath(item.url.deletingLastPathComponent())
        }
    }

    static func tagText(_ tags: [String]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, tag) in tags.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "  ")) }
            text.append(
                NSAttributedString(
                    string: "● ", attributes: [.foregroundColor: Palette.tagColor(tag) ?? Palette.secondaryText]))
            text.append(NSAttributedString(string: tag, attributes: [.foregroundColor: Palette.secondaryText]))
        }
        return text
    }
}
