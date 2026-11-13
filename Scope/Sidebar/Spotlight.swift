import Foundation

/// Runs a Spotlight query and hands back the matching paths, then keeps
/// reporting as the index changes. Results come from the Spotlight index, not
/// from reading the disk, so this runs on the main thread like NSMetadataQuery
/// expects. Stress launches scope every query to the verified image volumes.
@MainActor
final class SpotlightQuery {
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private let onResults: ([URL]) -> Void

    init(
        predicate: NSPredicate, scopes: [Any], sortByLastUsed: Bool = false, limit: Int? = nil,
        onResults: @escaping ([URL]) -> Void
    ) {
        self.onResults = onResults
        query.predicate = predicate
        query.searchScopes = scopes
        if sortByLastUsed {
            query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(
                center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publish(limit: limit) }
                })
        }
        query.start()
    }

    func stop() {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func publish(limit: Int?) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        let count = limit.map { min(query.resultCount, $0) } ?? query.resultCount
        var urls: [URL] = []
        urls.reserveCapacity(count)
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            urls.append(URL(fileURLWithPath: path))
        }
        onResults(urls)
    }

    /// Where global Recents and Tags queries look.
    static var scopes: [Any] {
        if let stress = BuildIdentity.stress { return [stress.source, stress.target] }
        return [NSMetadataQueryLocalComputerScope]
    }

    /// Files used in the last 30 days, newest first, like Finder's Recents.
    static func recents(onResults: @escaping ([URL]) -> Void) -> SpotlightQuery {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let predicate = NSPredicate(
            format: "%K > %@ AND %K != 'public.folder'",
            NSMetadataItemLastUsedDateKey, cutoff as NSDate,
            NSMetadataItemContentTypeKey)
        return SpotlightQuery(
            predicate: predicate, scopes: scopes, sortByLastUsed: true, limit: 500, onResults: onResults)
    }

    /// Files whose contents (or name) contain `text`, from the Spotlight index,
    /// under `folder`.
    static func contents(_ text: String, in folder: URL, onResults: @escaping ([URL]) -> Void) -> SpotlightQuery {
        let predicate = NSPredicate(
            format: "(%K CONTAINS[cd] %@) OR (%K CONTAINS[cd] %@)",
            "kMDItemTextContent", text, NSMetadataItemDisplayNameKey, text)
        return SpotlightQuery(predicate: predicate, scopes: [folder], onResults: onResults)
    }

    /// Items carrying one Finder tag.
    static func tagged(_ tag: String, onResults: @escaping ([URL]) -> Void) -> SpotlightQuery {
        let predicate = NSPredicate(format: "kMDItemUserTags == %@", tag)
        return SpotlightQuery(predicate: predicate, scopes: scopes, onResults: onResults)
    }
}

/// The Finder tags in use, for the sidebar: the seven colour tags plus any
/// other tag Spotlight finds on an item.
@MainActor
final class TagCatalog {
    static let colorTags = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]
    private static let attribute = "kMDItemUserTags"

    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private(set) var tags: [String] = colorTags
    var onChange: (() -> Void)?

    func start() {
        // Spotlight's own query syntax: "any value" is a wildcard there.
        query.predicate = NSPredicate(fromMetadataQueryString: "\(Self.attribute) == '*'")
        query.searchScopes = SpotlightQuery.scopes
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.collect() }
                })
        }
        query.start()
    }

    private func collect() {
        // Tag names come from the index, not from the files. Value lists would
        // be cheaper but come back empty for multi-value attributes like tags.
        query.disableUpdates()
        defer { query.enableUpdates() }
        var found = Set<String>()
        for index in 0..<query.resultCount {
            if let item = query.result(at: index) as? NSMetadataItem,
                let tags = item.value(forAttribute: Self.attribute) as? [String]
            {
                found.formUnion(tags)
            }
        }
        let custom = found.subtracting(Self.colorTags).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let updated = Self.colorTags + custom
        guard updated != tags else { return }
        tags = updated
        onChange?()
    }
}
