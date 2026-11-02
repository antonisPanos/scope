import Foundation
import ScopeEngine

/// A visible descendant shares the same listing, watcher and operation
/// announcements as a top-level tab. Its owner releases it on collapse.
@MainActor
final class NestedFolderListing {
    private var subscription: FolderStore.Subscription?
    private var task: Task<Void, Never>?
    private var revision = 0
    private var sort: FileSort
    private var showHidden: Bool
    private let onItems: ([FileItem]) -> Void

    init(
        url: URL, model: BrowserModel, onItems: @escaping ([FileItem]) -> Void
    ) {
        sort = model.sort
        showHidden = AppSettings.shared.showHiddenFiles
        self.onItems = onItems
        subscription = FolderStore.shared.open(url, engine: model.engine, announcements: model.announcements) {
            [weak self] _ in self?.refresh()
        }
        refresh()
    }

    isolated deinit {
        task?.cancel()
        if let subscription { FolderStore.shared.close(subscription) }
    }

    func update(sort: FileSort, showHidden: Bool) {
        guard sort != self.sort || showHidden != self.showHidden else { return }
        self.sort = sort
        self.showHidden = showHidden
        refresh()
    }

    private func refresh() {
        guard let folder = subscription?.folder else { return }
        revision += 1
        let revision = revision
        let items = folder.items
        let sort = sort
        let showHidden = showHidden
        task?.cancel()
        task = Task { [weak self] in
            let sorted = await Task.detached {
                sort.sorted(showHidden ? items : items.filter { !$0.isHidden })
            }.value
            guard let self, self.revision == revision, !Task.isCancelled else { return }
            self.onItems(sorted)
        }
    }
}
