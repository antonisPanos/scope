import Foundation

/// Finder tags: adding one to items or taking it off. Only the tag named
/// changes; every other tag an item has stays as it was.
extension FileEngine {
    func setTag(_ tag: String, applied: Bool, on items: [URL], control: OperationControl) throws {
        let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !name.contains("\n"), !name.utf8.contains(0) else { throw FileEngineError.invalidName(name) }
        control.update { $0.itemsTotal = items.count }
        for item in items {
            try Task.checkCancellation()
            let target = try pathGuard.checkWriteLocation(item)
            control.update { $0.currentItem = target.lastPathComponent }
            let location = try CopyLocation(checked: target)
            let descriptor = try FinderTags.open(location)
            var tags = try FinderTags.read(descriptor, path: target.path)
            let had = tags.contains { FinderTags.name(of: $0) == name }
            if applied, !had {
                tags.append(FinderTags.encode(name))
            } else if !applied, had {
                tags.removeAll { FinderTags.name(of: $0) == name }
            } else {
                control.update { $0.itemsDone += 1 }
                continue
            }
            // Never let a path-based Foundation setter follow a substituted link.
            try location.validateParent(pathGuard: pathGuard)
            try FinderTags.write(tags, to: descriptor, path: target.path)
            control.update { $0.itemsDone += 1 }
        }
    }
}
