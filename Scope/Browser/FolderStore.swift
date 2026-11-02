import Foundation
import ScopeEngine
import os

/// One listing and one watcher per folder, shared by every tab that shows
/// it. A folder stays for a while after its last tab leaves, still watched
/// so it stays current, which makes Back (or a new tab on it) instant.
///
/// The store keeps the folder's items in disk order with hidden ones
/// included; each tab filters and sorts its own copy.
@MainActor
final class FolderStore {
    static let shared = FolderStore()

    /// What happened to a folder, for the tabs showing it.
    enum Event {
        /// More of the listing arrived.
        case listed
        /// The listing is complete.
        case loaded
        /// Some children changed, on disk or by an operation. `added` names
        /// what appeared, and `operation` which operation said so, if one did.
        case updated(added: Set<String>, operation: UUID?)
        /// The folder can't be read (deleted, or its disk was ejected).
        case failed(String)
        /// It is being read again from scratch, as for Reload.
        case reset
    }

    @MainActor
    final class Folder {
        let url: URL
        fileprivate let engine: FileEngine
        fileprivate let announcements: OperationAnnouncements?
        fileprivate(set) var items: [FileItem] = [] {
            didSet { version += 1 }
        }
        /// Bumped whenever `items` changes.
        private(set) var version = 0
        /// The last filtered and sorted copy a tab made of `items`, so
        /// another tab, or Back, with the same settings shows it at once
        /// instead of sorting a big folder again.
        private var sortedCopy: (version: Int, sort: FileSort, showHidden: Bool, items: [FileItem])?
        fileprivate(set) var isLoaded = false
        fileprivate(set) var failure: String?
        fileprivate var observers: [UUID: (Event) -> Void] = [:]
        fileprivate var listTask: Task<Void, Never>?
        fileprivate var watchTask: Task<Void, Never>?
        /// Bumped on each (re)start, so work from an earlier run is ignored.
        fileprivate var run = 0
        fileprivate var isListing = false
        /// Set when the watcher changed the items before the listing finished,
        /// so later batches merge by name instead of adding duplicates.
        fileprivate var changedWhileListing = false
        fileprivate var idleSince: ContinuousClock.Instant?

        fileprivate init(url: URL, engine: FileEngine, announcements: OperationAnnouncements?) {
            self.url = url
            self.engine = engine
            self.announcements = announcements
        }

        /// The items as a tab with these settings shows them, if a tab has
        /// sorted the current items that way.
        func sorted(by sort: FileSort, showHidden: Bool) -> [FileItem]? {
            guard let sortedCopy, sortedCopy.version == version, sortedCopy.sort == sort,
                sortedCopy.showHidden == showHidden
            else { return nil }
            return sortedCopy.items
        }

        /// Keeps a tab's sorted copy of the items as they were at `version`.
        func keepSorted(_ items: [FileItem], of version: Int, by sort: FileSort, showHidden: Bool) {
            guard version == self.version else { return }
            sortedCopy = (version, sort, showHidden, items)
        }

        fileprivate func send(_ event: Event) {
            for observer in observers.values { observer(event) }
        }
    }

    struct Subscription {
        let folder: Folder
        fileprivate let id: UUID
    }

    /// How many folders no tab shows are kept, and for how long.
    static let idleLimit = 8
    static let idleTime: Duration = .seconds(120)

    private var folders: [String: Folder] = [:]
    private static let logger = Logger(subsystem: "com.antonispanos.scope", category: "Browser")

    /// Starts telling `observer` about `url`. The folder's current items are
    /// in the subscription's `folder` straight away when it is already known.
    func open(
        _ url: URL, engine: FileEngine, announcements: OperationAnnouncements?,
        observer: @escaping (Event) -> Void
    ) -> Subscription {
        let key = Self.key(url)
        let folder: Folder
        if let known = folders[key] {
            folder = known
            // A folder that couldn't be read may be back (a disk mounted again).
            if folder.failure != nil { restart(folder) }
        } else {
            folder = Folder(url: url, engine: engine, announcements: announcements)
            folders[key] = folder
            start(folder)
        }
        folder.idleSince = nil
        let id = UUID()
        folder.observers[id] = observer
        return Subscription(folder: folder, id: id)
    }

    func close(_ subscription: Subscription) {
        let folder = subscription.folder
        folder.observers[subscription.id] = nil
        guard folder.observers.isEmpty else { return }
        folder.idleSince = .now
        evictIdle()
        Task { [weak self] in
            try? await Task.sleep(for: Self.idleTime + .seconds(1))
            self?.evictIdle()
        }
    }

    /// Reads the folder again from scratch, for every tab showing it.
    func reload(_ folder: Folder) {
        restart(folder)
    }

    // MARK: - Keeping folders

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    private func evictIdle() {
        let idle = folders.compactMap { key, folder in
            folder.idleSince.map { (key: key, since: $0, failed: folder.failure != nil) }
        }
        for key in Self.evictable(idle, now: .now, limit: Self.idleLimit, after: Self.idleTime) {
            guard let folder = folders.removeValue(forKey: key) else { continue }
            stop(folder)
        }
    }

    /// Which idle folders to drop: failed ones, ones idle longer than
    /// `after`, and the oldest beyond `limit`.
    nonisolated static func evictable(
        _ idle: [(key: String, since: ContinuousClock.Instant, failed: Bool)], now: ContinuousClock.Instant,
        limit: Int, after: Duration
    ) -> [String] {
        let expired = idle.filter { $0.failed || now - $0.since > after }
        let kept = idle.filter { !($0.failed || now - $0.since > after) }.sorted { $0.since > $1.since }
        return expired.map(\.key) + kept.dropFirst(limit).map(\.key)
    }

    private func start(_ folder: Folder) {
        folder.run += 1
        let run = folder.run
        folder.listTask = Task { await list(folder, run: run) }
        watch(folder, run: run)
    }

    private func stop(_ folder: Folder) {
        folder.run += 1
        folder.listTask?.cancel()
        folder.watchTask?.cancel()
        folder.listTask = nil
        folder.watchTask = nil
    }

    private func restart(_ folder: Folder) {
        stop(folder)
        folder.items = []
        folder.isLoaded = false
        folder.failure = nil
        folder.isListing = false
        folder.changedWhileListing = false
        folder.send(.reset)
        start(folder)
    }

    // MARK: - Listing and watching

    private func list(_ folder: Folder, run: Int) async {
        folder.isListing = true
        defer { if folder.run == run { folder.isListing = false } }
        do {
            for try await batch in try folder.engine.listing(of: folder.url) {
                guard folder.run == run else { return }
                if folder.changedWhileListing {
                    let names = Set(batch.map(\.url.lastPathComponent))
                    folder.items = FolderListing.updating(folder.items, names: names, with: batch)
                } else {
                    folder.items += batch
                }
                folder.send(.listed)
            }
            guard folder.run == run else { return }
            folder.isLoaded = true
            folder.send(.loaded)
        } catch is CancellationError {
        } catch {
            await fail(folder, run: run, error)
        }
    }

    private func fail(_ folder: Folder, run: Int, _ error: any Error) async {
        guard folder.run == run else { return }
        let url = folder.url
        Self.logger.error(
            "Listing \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        let message = await Task.detached { BrowserModel.describe(error, at: url) }.value
        guard folder.run == run else { return }
        stop(folder)
        folder.items = []
        folder.failure = message
        folder.send(.failed(message))
    }

    /// One change to a folder: from the watcher, or announced by an
    /// operation as it made it (with what it added, and which one).
    private struct Update: Sendable {
        var change: FolderChange
        var added: Set<String> = []
        var operation: UUID?
    }

    /// Follows the folder as it changes: only the children that changed are
    /// read again. Operations announce their changes at once; the watcher
    /// catches everything else (other apps, other disks), and re-reading a
    /// change already applied finds nothing new.
    private func watch(_ folder: Folder, run: Int) {
        let url = folder.url
        let (updates, continuation) = AsyncStream.makeStream(of: Update.self)
        var feeds: [@Sendable () -> Void] = []
        let watchFeed = Task {
            guard let events = try? await folder.engine.folderEvents(at: url), !Task.isCancelled else { return }
            for await change in events { continuation.yield(Update(change: change)) }
        }
        feeds.append { watchFeed.cancel() }
        if let announcements = folder.announcements {
            let token = announcements.observe { change in
                // On the operation's worker thread, so resolving links here
                // keeps the disk off the main thread.
                let changed = change.folder.resolvingSymlinksInPath().path
                guard changed == url.resolvingSymlinksInPath().path else { return }
                continuation.yield(
                    Update(change: .children(change.names), added: change.added, operation: change.operation))
            }
            feeds.append { announcements.stop(token) }
        }
        guard !feeds.isEmpty else { return }
        continuation.onTermination = { [feeds] _ in feeds.forEach { $0() } }
        folder.watchTask = Task {
            defer { continuation.finish() }
            for await update in updates {
                guard folder.run == run else { return }
                if folder.isListing { folder.changedWhileListing = true }
                do {
                    switch update.change {
                    case .children(let names):
                        let fresh = try await folder.engine.children(named: names, in: url)
                        guard folder.run == run else { return }
                        folder.items = FolderListing.updating(folder.items, names: names, with: fresh)
                    case .everything:
                        let listed = try await folder.engine.contentsOfDirectory(at: url)
                        guard folder.run == run else { return }
                        folder.items = listed
                    }
                    folder.send(.updated(added: update.added, operation: update.operation))
                } catch {
                    await fail(folder, run: run, error)
                    return
                }
            }
        }
    }
}
