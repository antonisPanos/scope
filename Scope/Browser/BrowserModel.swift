import Foundation
import ScopeEngine
import os

/// The state of one browser tab: where it is, what it shows, and its history.
///
/// All disk work happens in the engine, off the main thread; this model only
/// holds the resulting snapshots. Views register for changes through
/// `onChange` and redraw from the snapshot.
@MainActor
final class BrowserModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    struct Change: OptionSet {
        let rawValue: Int
        static let location = Change(rawValue: 1 << 0)
        static let items = Change(rawValue: 1 << 1)
        static let viewMode = Change(rawValue: 1 << 2)
        static let state = Change(rawValue: 1 << 3)
        static let sort = Change(rawValue: 1 << 4)
        static let status = Change(rawValue: 1 << 5)
        /// The folder changed on disk and `items` was updated in place;
        /// `rowChanges` says which rows to remove, insert and redraw.
        static let itemsUpdated = Change(rawValue: 1 << 6)
        /// Either kind of items change.
        static let anyItems: Change = [.items, .itemsUpdated]
    }

    let engine: FileEngine
    /// Changes operations make, as they make them; nil in a tab that doesn't follow them.
    let announcements: OperationAnnouncements?
    var onChange: ((Change) -> Void)?

    private(set) var location: Location
    private(set) var items: [FileItem] = []
    private(set) var state: LoadState = .loading
    /// Free space on the volume being shown, for the status bar.
    private(set) var availableCapacity: Int64?
    /// Items to select once they show up: after "Go to" a file, or the
    /// items an operation started from this tab added.
    var pendingSelection: [URL] = []
    /// True while a search is still crawling.
    private(set) var isSearching = false
    /// How `items` changed, set only while `.itemsUpdated` is announced.
    private(set) var rowChanges: FolderListing.RowChanges?

    var viewMode: ViewMode {
        didSet {
            guard viewMode != oldValue else { return }
            AppSettings.shared.lastViewMode = viewMode
            onChange?(.viewMode)
        }
    }

    var sort: FileSort {
        didSet {
            guard sort != oldValue else { return }
            AppSettings.shared.lastSort = sort
            Task { await applyFilterAndSort() }
            onChange?(.sort)
        }
    }

    private var allItems: [FileItem] = []
    /// The shared listing's version `allItems` was taken from, for its
    /// sorted copy; nil for searches, Recents and Tags.
    private var allItemsVersion: Int?
    private var backStack: [Location] = []
    private var forwardStack: [Location] = []
    private var loadTask: Task<Void, Never>?
    /// The shared listing of the folder on screen.
    private var subscription: FolderStore.Subscription?
    /// A pending re-sort while a listing arrives, and when the last one ran.
    private var listingSort: Task<Void, Never>?
    private var lastListingSort: ContinuousClock.Instant?
    private var spotlight: SpotlightQuery?
    private var settingsObserver: NSObjectProtocol?
    private var generation = 0
    /// What recent operations added to this folder, so the window that
    /// started one can select it even when the news came first.
    private var addedBy: [(operation: UUID, urls: [URL])] = []
    /// The operation whose new items get selected as they show up.
    private var selectingOperation: UUID?

    private static let logger = Logger(subsystem: "com.antonispanos.scope", category: "Browser")

    init(engine: FileEngine, location: Location, announcements: OperationAnnouncements? = nil) {
        self.engine = engine
        self.announcements = announcements
        self.location = location
        self.viewMode = AppSettings.shared.lastViewMode
        self.sort = AppSettings.shared.lastSort
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.applyFilterAndSort() }
            }
        }
        load()
    }

    /// Stops watching and querying; call when the tab closes so it releases everything it held.
    func close() {
        loadTask?.cancel()
        unsubscribe()
        spotlight?.stop()
        spotlight = nil
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
    }

    // MARK: - Navigation

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    var canGoUp: Bool {
        guard let url = location.searchRoot else { return false }
        let parent = url.deletingLastPathComponent()
        return parent.path != url.path && engine.pathGuard.permits(parent)
    }

    func navigate(to destination: Location, select: URL? = nil) {
        pendingSelection = select.map { [$0] } ?? []
        guard destination != location else {
            if select != nil { onChange?(.items) }
            return
        }
        backStack.append(location)
        forwardStack.removeAll()
        location = destination
        load()
    }

    /// Shows another location without adding to the history; a search
    /// being refined keystroke by keystroke shouldn't fill the Back list.
    func replace(with destination: Location) {
        guard destination != location else { return }
        location = destination
        load()
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(location)
        pendingSelection = location.folderURL.map { [$0] } ?? []
        location = previous
        load()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        location = next
        load()
    }

    func goUp() {
        guard canGoUp, let url = location.searchRoot else { return }
        navigate(to: .folder(url.deletingLastPathComponent()), select: url)
    }

    /// Reads the location again; a folder is read again from scratch for
    /// every tab showing it.
    func reload() {
        if case .folder = location, let folder = subscription?.folder {
            FolderStore.shared.reload(folder)
        } else {
            load()
        }
    }

    // MARK: - Loading

    private func load() {
        generation += 1
        let generation = generation
        loadTask?.cancel()
        unsubscribe()
        spotlight?.stop()
        spotlight = nil
        isSearching = false
        state = .loading
        addedBy = []
        selectingOperation = nil
        lastListingSort = nil
        allItems = []
        allItemsVersion = nil
        items = []
        availableCapacity = nil
        onChange?([.location, .items, .state, .status])

        switch location {
        case .folder(let url):
            openFolder(url, generation: generation)
        case .recents:
            spotlight = SpotlightQuery.recents { [weak self] urls in self?.loadItems(at: urls, generation: generation) }
        case .tag(let tag):
            spotlight = SpotlightQuery.tagged(tag) { [weak self] urls in
                self?.loadItems(at: urls, generation: generation)
            }
        case .search(let query, let folder):
            if query.searchContents {
                spotlight = SpotlightQuery.contents(query.text, in: folder) { [weak self] urls in
                    self?.loadItems(at: urls, generation: generation)
                }
            } else {
                loadTask = Task { await runSearch(query, in: folder, generation: generation) }
            }
        }
    }

    /// Shows a folder from its shared listing: at once when another tab (or
    /// a recent visit) already has it, otherwise as it is read, the first
    /// batch at once and the rest re-sorted at most every quarter second.
    private func openFolder(_ url: URL, generation: Int) {
        let store = FolderStore.shared
        let subscription = store.open(url, engine: engine, announcements: announcements) { [weak self] event in
            self?.folderChanged(event, in: url, generation: generation)
        }
        self.subscription = subscription
        let folder = subscription.folder
        if folder.isLoaded, let sorted = folder.sorted(by: sort, showHidden: AppSettings.shared.showHiddenFiles) {
            // Already sorted this way by another tab or an earlier visit: no wait at all.
            takeItems(of: folder)
            items = sorted
            state = .loaded
            onChange?([.items, .state, .status])
            loadTask = Task { await loadCapacity(url, generation: generation) }
        } else if folder.isLoaded {
            folderChanged(.loaded, in: url, generation: generation)
        } else if !folder.items.isEmpty {
            showListing(generation: generation)
        }
    }

    private func takeItems(of folder: FolderStore.Folder) {
        allItems = folder.items
        allItemsVersion = folder.version
    }

    private func unsubscribe() {
        if let subscription { FolderStore.shared.close(subscription) }
        subscription = nil
        listingSort?.cancel()
        listingSort = nil
    }

    private func folderChanged(_ event: FolderStore.Event, in url: URL, generation: Int) {
        guard generation == self.generation, let folder = subscription?.folder else { return }
        switch event {
        case .listed:
            showListing(generation: generation)
        case .loaded:
            loadTask = Task {
                takeItems(of: folder)
                await applyFilterAndSort()
                guard generation == self.generation else { return }
                if state != .loaded {
                    state = .loaded
                    onChange?(.state)
                }
                await loadCapacity(url, generation: generation)
            }
        case .updated(let added, let operation):
            takeItems(of: folder)
            if let operation, !added.isEmpty {
                noteAdded(added.map { url.appendingPathComponent($0) }, by: operation)
            }
            Task { await applyFilterAndSort(inPlace: true) }
        case .failed(let message):
            allItems = []
            allItemsVersion = nil
            items = []
            state = .failed(message)
            onChange?([.items, .state, .status])
        case .reset:
            allItems = []
            allItemsVersion = nil
            items = []
            state = .loading
            lastListingSort = nil
            onChange?([.items, .state, .status])
        }
    }

    /// Re-sorts the listing so far, at most every quarter second.
    private func showListing(generation: Int) {
        guard listingSort == nil else { return }
        let wait = lastListingSort.map { Duration.milliseconds(250) - (ContinuousClock.now - $0) } ?? .zero
        listingSort = Task {
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard generation == self.generation else { return }
            listingSort = nil
            guard let folder = subscription?.folder, !folder.isLoaded else { return }
            lastListingSort = .now
            takeItems(of: folder)
            await applyFilterAndSort()
            guard generation == self.generation else { return }
            // Shown as soon as there is something to show; an empty first
            // batch (all hidden) would flash "empty folder".
            if state == .loading, !items.isEmpty {
                state = .loaded
                onChange?(.state)
            }
        }
    }

    /// Streams search results in as the crawler finds them, re-sorting at
    /// most every quarter second so a big result set doesn't stall the list.
    private func runSearch(_ query: SearchQuery, in folder: URL, generation: Int) async {
        guard generation == self.generation, !Task.isCancelled else { return }
        isSearching = true
        onChange?(.status)
        defer {
            if generation == self.generation {
                isSearching = false
                onChange?(.status)
            }
        }
        do {
            var lastSort = ContinuousClock.now
            for try await batch in try engine.search(query, in: folder) {
                guard generation == self.generation else { return }
                allItems += batch
                if ContinuousClock.now - lastSort > .milliseconds(250) {
                    lastSort = .now
                    await applyFilterAndSort()
                    if state == .loading {
                        state = .loaded
                        onChange?(.state)
                    }
                }
            }
            guard generation == self.generation else { return }
            await applyFilterAndSort()
            state = .loaded
            onChange?(.state)
        } catch is CancellationError {
        } catch {
            guard generation == self.generation else { return }
            state = .failed(error.localizedDescription)
            onChange?(.state)
        }
    }

    /// Stops a running search and keeps what it found so far.
    func stopSearch() {
        guard isSearching else { return }
        loadTask?.cancel()
        isSearching = false
        Task { await applyFilterAndSort() }
        state = .loaded
        onChange?([.state, .status])
    }

    private func loadItems(at urls: [URL], generation: Int) {
        loadTask?.cancel()
        loadTask = Task {
            guard let found = try? await engine.items(at: urls), generation == self.generation else { return }
            allItems = found
            await applyFilterAndSort()
            guard generation == self.generation else { return }
            state = .loaded
            onChange?(.state)
        }
    }

    private func loadCapacity(_ url: URL, generation: Int) async {
        let capacity = await Task.detached(priority: .utility) {
            try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        }.value
        guard generation == self.generation else { return }
        availableCapacity = capacity ?? nil
        onChange?(.status)
    }

    // MARK: - Selecting what an operation added

    /// Selects the items `operation` adds to this folder: those it already
    /// added and those still to come, until the tab moves elsewhere or
    /// another operation is selected.
    func selectItems(addedBy operation: UUID) {
        selectingOperation = operation
        guard let urls = addedBy.first(where: { $0.operation == operation })?.urls else { return }
        pendingSelection = urls
        onChange?(.items)
    }

    private func noteAdded(_ urls: [URL], by operation: UUID) {
        if let index = addedBy.firstIndex(where: { $0.operation == operation }) {
            addedBy[index].urls += urls.filter { !addedBy[index].urls.contains($0) }
        } else {
            addedBy.append((operation, urls))
            if addedBy.count > 8 { addedBy.removeFirst() }
        }
        if operation == selectingOperation, let all = addedBy.first(where: { $0.operation == operation })?.urls {
            pendingSelection = all
        }
    }

    /// Hides hidden items unless they're switched on, then sorts, off the main
    /// thread. With `inPlace` (a change on disk), the views are told which
    /// rows changed instead of reloading, and nothing if no row did.
    private func applyFilterAndSort(inPlace: Bool = false) async {
        let source = allItems
        let sort = sort
        // Search results already follow the query's own hidden-files switch.
        let showHidden = AppSettings.shared.showHiddenFiles || location.isSearch
        let generation = generation
        let old = items
        // A folder's items another tab (or an earlier visit) already sorted this way.
        let version = allItemsVersion
        let shared = version == nil ? nil : subscription?.folder
        let known = shared.flatMap { $0.version == version ? $0.sorted(by: sort, showHidden: showHidden) : nil }
        let (result, changes) = await Task.detached(priority: .userInitiated) {
            let result = known ?? sort.sorted(showHidden ? source : source.filter { !$0.isHidden })
            return (result, inPlace ? FolderListing.rowChanges(from: old, to: result) : nil)
        }.value
        guard generation == self.generation else { return }
        if let shared, let version, known == nil {
            shared.keepSorted(result, of: version, by: sort, showHidden: showHidden)
        }
        // Another update may have landed meanwhile; the row changes are only
        // right against the rows they were worked out from.
        guard let changes, items == old else {
            items = result
            onChange?([.items, .status])
            return
        }
        // Nothing moved, but items an operation added may still need selecting.
        guard !changes.isEmpty || !pendingSelection.isEmpty else { return }
        Self.logger.debug(
            "Rows changed: \(changes.removed.count) removed, \(changes.inserted.count) added, \(changes.reloaded.count) redrawn"
        )
        items = result
        rowChanges = changes
        onChange?([.itemsUpdated, .status])
        rowChanges = nil
    }

    /// Runs off the main thread: it may check whether the folder still exists.
    nonisolated static func describe(_ error: Error, at url: URL) -> String {
        if let violation = error as? PathGuardViolation {
            return violation.description
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            return "\(url.path) doesn't exist anymore."
        }
        return error.localizedDescription
    }
}
