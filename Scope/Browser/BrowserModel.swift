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
    var onChange: ((Change) -> Void)?

    private(set) var location: Location
    private(set) var items: [FileItem] = []
    private(set) var state: LoadState = .loading
    /// Free space on the volume being shown, for the status bar.
    private(set) var availableCapacity: Int64?
    /// An item to select once the next listing arrives (after "Go to" a file).
    var pendingSelection: URL?
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
    private var backStack: [Location] = []
    private var forwardStack: [Location] = []
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var spotlight: SpotlightQuery?
    private var settingsObserver: NSObjectProtocol?
    private var generation = 0

    private static let logger = Logger(subsystem: "com.antonispanos.scope", category: "Browser")

    init(engine: FileEngine, location: Location) {
        self.engine = engine
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
        watchTask?.cancel()
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
        pendingSelection = select
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
        pendingSelection = location.folderURL
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

    func reload() {
        load()
    }

    // MARK: - Loading

    private func load() {
        generation += 1
        let generation = generation
        loadTask?.cancel()
        watchTask?.cancel()
        spotlight?.stop()
        spotlight = nil
        state = .loading
        allItems = []
        items = []
        availableCapacity = nil
        onChange?([.location, .items, .state, .status])

        switch location {
        case .folder(let url):
            loadTask = Task { await loadFolder(url, generation: generation) }
            startWatching(url, generation: generation)
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

    private func loadFolder(_ url: URL, generation: Int) async {
        do {
            let listed = try await engine.contentsOfDirectory(at: url)
            guard generation == self.generation else { return }
            allItems = listed
            await applyFilterAndSort()
            guard generation == self.generation else { return }
            state = .loaded
            onChange?(.state)
            await loadCapacity(url, generation: generation)
        } catch is CancellationError {
        } catch {
            guard generation == self.generation else { return }
            Self.logger.error(
                "Listing \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            let message = await Task.detached { Self.describe(error, at: url) }.value
            guard generation == self.generation else { return }
            state = .failed(message)
            onChange?(.state)
        }
    }

    /// Streams search results in as the crawler finds them, re-sorting at
    /// most every quarter second so a big result set doesn't stall the list.
    private func runSearch(_ query: SearchQuery, in folder: URL, generation: Int) async {
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

    /// Follows the folder as it changes on disk, without clearing what is on
    /// screen in between: only the children that changed are read again,
    /// and the views update just those rows.
    private func startWatching(_ url: URL, generation: Int) {
        guard let events = try? FolderWatcher.events(in: url, pathGuard: engine.pathGuard) else { return }
        watchTask = Task { [weak self] in
            for await change in events {
                guard let self, generation == self.generation else { return }
                do {
                    switch change {
                    case .children(let names):
                        let fresh = try await self.engine.children(named: names, in: url)
                        guard generation == self.generation else { return }
                        self.allItems = FolderListing.updating(self.allItems, names: names, with: fresh)
                    case .everything:
                        let listed = try await self.engine.contentsOfDirectory(at: url)
                        guard generation == self.generation else { return }
                        self.allItems = listed
                    }
                    await self.applyFilterAndSort(inPlace: true)
                } catch {
                    // The folder went away: deleted, or its disk was ejected.
                    let message = await Task.detached { Self.describe(error, at: url) }.value
                    guard generation == self.generation else { return }
                    self.allItems = []
                    self.items = []
                    self.state = .failed(message)
                    self.onChange?([.items, .state, .status])
                }
            }
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
        let (result, changes) = await Task.detached(priority: .userInitiated) {
            let result = sort.sorted(showHidden ? source : source.filter { !$0.isHidden })
            return (result, inPlace ? FolderListing.rowChanges(from: old, to: result) : nil)
        }.value
        guard generation == self.generation else { return }
        // Another update may have landed meanwhile; the row changes are only
        // right against the rows they were worked out from.
        guard let changes, items == old else {
            items = result
            onChange?([.items, .status])
            return
        }
        guard !changes.isEmpty else { return }
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
            if violation.reason == .outsideAllowedRoots, BuildIdentity.current.isDevelopment {
                return "\(url.path) is outside the test disks, so Scope Dev won't open it."
            }
            return violation.description
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            if let disk = BuildIdentity.testDiskRoots.first(where: {
                url.path == $0.path || url.path.hasPrefix($0.path + "/")
            }) {
                return "\(disk.lastPathComponent) isn't mounted. Run scripts/testdisk.sh mount, then reload with Cmd+R."
            }
            return "\(url.path) doesn't exist anymore."
        }
        return error.localizedDescription
    }
}
