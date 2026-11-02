import Foundation

/// Finder tags: adding one to items or taking it off. Only the tag named
/// changes; every other tag an item has stays as it was.
extension FileEngine {
    func setTag(_ tag: String, applied: Bool, on items: [URL], control: OperationControl) throws {
        let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        control.update { $0.itemsTotal = items.count }
        for item in items {
            try Task.checkCancellation()
            let target = try pathGuard.checkWriteLocation(item)
            control.update { $0.currentItem = target.lastPathComponent }
            var tags = try target.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
            let had = tags.contains(name)
            if applied, !had {
                tags.append(name)
            } else if !applied, had {
                tags.removeAll { $0 == name }
            } else {
                control.update { $0.itemsDone += 1 }
                continue
            }
            // URLResourceValues can't set tags; NSURL can.
            try (target as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            control.update { $0.itemsDone += 1 }
        }
    }
}
