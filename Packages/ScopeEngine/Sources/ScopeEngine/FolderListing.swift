import Foundation

/// Keeping a folder's listing current from the names a `FolderChange`
/// reports, instead of reading the whole folder again on every change.
extension FileEngine {
    /// The named children of `folder` as they are now. A name with no item
    /// in the result is gone.
    public func children(named names: Set<String>, in folder: URL) async throws -> [FileItem] {
        return try await onIOThreads {
            let directory = try pathGuard.checkTarget(folder)
            var items: [FileItem] = []
            for (index, name) in names.enumerated() {
                if index % 256 == 0 { try Task.checkCancellation() }
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { continue }
                let url = directory.appendingPathComponent(name)
                // A listing describes the link itself, even if its target
                // is missing, loops, or lives outside the readable roots.
                guard let location = try? pathGuard.checkLocation(url), let item = try? FileItem(url: location) else {
                    continue
                }
                items.append(item)
            }
            return items
        }
    }
}

public enum FolderListing {
    /// `items` with the named children replaced by `fresh`, their current
    /// state: a named child not in `fresh` is removed, and a new one added.
    /// The order of the others is kept; new items go at the end.
    public static func updating(_ items: [FileItem], names: Set<String>, with fresh: [FileItem]) -> [FileItem] {
        var byName: [String: FileItem] = [:]
        for item in fresh { byName[item.url.lastPathComponent] = item }
        var result: [FileItem] = []
        result.reserveCapacity(items.count + fresh.count)
        for item in items {
            let name = item.url.lastPathComponent
            guard names.contains(name) else {
                result.append(item)
                continue
            }
            if let current = byName.removeValue(forKey: name) { result.append(current) }
        }
        result.append(contentsOf: fresh.filter { byName[$0.url.lastPathComponent] != nil })
        return result
    }

    /// How a list of rows changed, for updating a table or collection view
    /// in place: remove `removed` (indexes in the old rows), then insert
    /// `inserted` (indexes in the new rows), then redraw `reloaded` (indexes
    /// in the new rows of items whose details changed).
    public struct RowChanges: Sendable, Equatable {
        public var removed = IndexSet()
        public var inserted = IndexSet()
        public var reloaded = IndexSet()

        public var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && reloaded.isEmpty }

        public init(removed: IndexSet = [], inserted: IndexSet = [], reloaded: IndexSet = []) {
            self.removed = removed
            self.inserted = inserted
            self.reloaded = reloaded
        }
    }

    /// The row changes that turn `old` into `new`, matching items by URL.
    public static func rowChanges(from old: [FileItem], to new: [FileItem]) -> RowChanges {
        var changes = RowChanges()
        for change in new.difference(from: old, by: { $0.url == $1.url }) {
            switch change {
            case .remove(let offset, _, _): changes.removed.insert(offset)
            case .insert(let offset, _, _): changes.inserted.insert(offset)
            }
        }
        var oldByURL: [URL: FileItem] = [:]
        for item in old { oldByURL[item.url] = item }
        for (index, item) in new.enumerated() where !changes.inserted.contains(index) {
            if let before = oldByURL[item.url], before != item { changes.reloaded.insert(index) }
        }
        return changes
    }
}
