import Foundation
import Synchronization

/// What one step of an operation changed in a folder: names that appeared
/// there (created, copied or moved in) and names that left it.
public struct FolderItemsChanged: Sendable, Equatable {
    public let folder: URL
    public let added: Set<String>
    public let removed: Set<String>

    public init(folder: URL, added: Set<String> = [], removed: Set<String> = []) {
        self.folder = folder
        self.added = added
        self.removed = removed
    }

    /// Every name that changed, for re-reading just those.
    public var names: Set<String> { added.union(removed) }

    /// The change that undoes this one.
    var reversed: FolderItemsChanged { FolderItemsChanged(folder: folder, added: removed, removed: added) }

    /// The folders a recorded step changed. Undo steps say exactly what each
    /// step did, so they are the source: a created item appeared in its
    /// folder; a move left the source folder for the target one; a trashed
    /// item left its folder.
    static func changes(for step: UndoStep) -> [FolderItemsChanged] {
        func parent(_ url: URL) -> URL { url.deletingLastPathComponent().standardizedFileURL }
        switch step {
        case .trashCreated(let url, _):
            return [FolderItemsChanged(folder: parent(url), added: [url.lastPathComponent])]
        case .moveBack(let target, let source):
            if parent(target) == parent(source) {
                return [
                    FolderItemsChanged(
                        folder: parent(target), added: [target.lastPathComponent], removed: [source.lastPathComponent])
                ]
            }
            return [
                FolderItemsChanged(folder: parent(target), added: [target.lastPathComponent]),
                FolderItemsChanged(folder: parent(source), removed: [source.lastPathComponent]),
            ]
        case .putBack(_, let original):
            return [FolderItemsChanged(folder: parent(original), removed: [original.lastPathComponent])]
        }
    }
}

/// Tells observers about each change operations make, as they make it. The
/// handlers run on the operation's worker thread; an app hops to its own.
/// The folder watcher still reports everything, including changes made by
/// other apps; an announced change it reports again finds nothing new.
public final class OperationAnnouncements: Sendable {
    private let handlers = Mutex<[UUID: @Sendable (FolderItemsChanged) -> Void]>([:])

    public init() {}

    /// Starts telling `handler` about changes; returns a token for `stop`.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable (FolderItemsChanged) -> Void) -> UUID {
        let id = UUID()
        handlers.withLock { $0[id] = handler }
        return id
    }

    public func stop(_ id: UUID) {
        _ = handlers.withLock { $0.removeValue(forKey: id) }
    }

    func announce(_ change: FolderItemsChanged) {
        for handler in handlers.withLock({ Array($0.values) }) { handler(change) }
    }
}
