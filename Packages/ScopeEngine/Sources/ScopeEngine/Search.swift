import Foundation
import UniformTypeIdentifiers

/// What to look for. Name matching is case- and accent-insensitive.
public struct SearchQuery: Sendable, Hashable {
    public enum Mode: String, Sendable, Hashable, CaseIterable {
        /// The name contains the text.
        case contains
        /// Shell-style pattern: `*.pdf`, `IMG_2026*`, `report-??.txt`.
        case glob
        /// Regular expression against the whole name.
        case regex
    }

    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case folder, document, image, movie, audio, archive, application, other
    }

    public var text: String
    public var mode: Mode
    public var includeHidden: Bool
    public var includeSubfolders: Bool
    /// Look inside app bundles and other packages.
    public var includePackages: Bool
    /// Empty means any kind.
    public var kinds: Set<Kind>
    public var minimumSize: Int64?
    public var maximumSize: Int64?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var tag: String?
    /// Look in file contents through the Spotlight index instead of crawling.
    /// The crawler ignores this; the app routes such queries to Spotlight.
    public var searchContents = false

    public init(
        text: String = "", mode: Mode = .contains, includeHidden: Bool = false, includeSubfolders: Bool = true,
        includePackages: Bool = false, kinds: Set<Kind> = [], minimumSize: Int64? = nil, maximumSize: Int64? = nil,
        modifiedAfter: Date? = nil, modifiedBefore: Date? = nil, tag: String? = nil
    ) {
        self.text = text
        self.mode = mode
        self.includeHidden = includeHidden
        self.includeSubfolders = includeSubfolders
        self.includePackages = includePackages
        self.kinds = kinds
        self.minimumSize = minimumSize
        self.maximumSize = maximumSize
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.tag = tag
    }

    /// Whether any condition is set; an empty query matches nothing.
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty && kinds.isEmpty && minimumSize == nil && maximumSize == nil
            && modifiedAfter == nil && modifiedBefore == nil && tag == nil
    }
}

public enum SearchError: Error, Equatable, LocalizedError {
    case invalidPattern(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPattern(let message): "That pattern isn't valid: \(message)"
        }
    }
}

/// Decides whether one item matches a query. Built once per search.
struct SearchMatcher: @unchecked Sendable {
    let query: SearchQuery
    private let needle: String
    private let glob: [CChar]?
    // NSRegularExpression is immutable and safe to share between threads.
    private let regex: NSRegularExpression?

    init(_ query: SearchQuery) throws {
        self.query = query
        let text = query.text.trimmingCharacters(in: .whitespaces)
        needle = text
        switch query.mode {
        case .contains:
            glob = nil
            regex = nil
        case .glob:
            glob = text.isEmpty ? nil : Array(text.utf8CString)
            regex = nil
        case .regex:
            glob = nil
            do {
                regex = text.isEmpty ? nil : try NSRegularExpression(pattern: text, options: [.caseInsensitive])
            } catch {
                throw SearchError.invalidPattern(error.localizedDescription)
            }
        }
    }

    func nameMatches(_ name: String) -> Bool {
        guard !needle.isEmpty else { return true }
        switch query.mode {
        case .contains:
            return name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .glob:
            guard let glob else { return true }
            return name.withCString { fnmatch(glob, $0, FNM_CASEFOLD) == 0 }
        case .regex:
            guard let regex else { return true }
            let range = NSRange(name.startIndex..., in: name)
            return regex.firstMatch(in: name, range: range) != nil
        }
    }

    /// Everything except the tag, which costs a read per item and is checked last.
    func matches(_ item: FileItem) -> Bool {
        guard nameMatches(item.name) else { return false }
        if !query.kinds.isEmpty, !query.kinds.contains(Self.kind(of: item)) { return false }
        if let minimum = query.minimumSize, (item.size ?? 0) < minimum { return false }
        if let maximum = query.maximumSize, let size = item.size, size > maximum { return false }
        if query.maximumSize != nil, item.size == nil { return false }
        if let after = query.modifiedAfter, (item.modified ?? .distantPast) < after { return false }
        if let before = query.modifiedBefore, (item.modified ?? .distantFuture) > before { return false }
        return true
    }

    static func kind(of item: FileItem) -> SearchQuery.Kind {
        if item.isBrowsableFolder { return .folder }
        let pathExtension = item.url.pathExtension
        if FileEngine.isArchive(item.url) { return .archive }
        guard let type = UTType(filenameExtension: pathExtension, conformingTo: item.isPackage ? .package : .data)
        else {
            return .other
        }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return .application }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .movie }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .rtf) || type.conforms(to: .compositeContent)
        {
            return .document
        }
        return .other
    }
}

extension FileEngine {
    /// Searches `folder` (and its subfolders, unless the query says not to)
    /// with its own crawler, not the Spotlight index. Matches arrive in
    /// batches as they're found. Folders are listed in parallel; stopping the
    /// iteration, or cancelling the task, stops the crawl at once. Symlinks
    /// are never followed, so a crawl can't loop or leave the folder, and it
    /// stays on the disk it starts on: other mounted disks, shares and images
    /// are never entered. It stops after `searchResultLimit` matches.
    public func search(
        _ query: SearchQuery, in folder: URL, batchSize: Int = 200
    ) throws -> AsyncThrowingStream<[FileItem], Error> {
        let root = try pathGuard.checkTarget(folder)
        let matcher = try SearchMatcher(query)
        let engine = self
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [FileItem].self)

        let task = Task.detached(executorPreference: IOExecutor.shared, priority: .userInitiated) {
            do {
                try await engine.crawl(root, matcher: matcher, batchSize: batchSize) { batch in
                    continuation.yield(batch)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error is CancellationError ? nil : error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// A search stops after this many results; the UI says when it did.
    public static let searchResultLimit = 10_000

    /// The startup disk's data volume, which macOS also shows through "/"
    /// (firmlinks). Searching from "/" skips this path so nothing appears twice.
    static let dataVolumePath = "/System/Volumes/Data"

    /// The devices a search from `root` may enter: only the disk it starts on.
    /// The startup disk counts as one disk although it is two volumes (system
    /// and data); every other mounted disk, share or image is left out.
    static func searchDevices(for root: URL) -> Set<dev_t> {
        guard let rootDevice = lstatInfo(root.path)?.st_dev else { return [] }
        let startup = [lstatInfo("/")?.st_dev, lstatInfo(dataVolumePath)?.st_dev].compactMap { $0 }
        return startup.contains(rootDevice) ? Set(startup) : [rootDevice]
    }

    private func crawl(
        _ root: URL, matcher: SearchMatcher, batchSize: Int,
        emit: @escaping @Sendable ([FileItem]) -> Void
    ) async throws {
        let query = matcher.query
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let devices = Self.searchDevices(for: root)
        var pending: [URL] = [root]
        var batch: [FileItem] = []
        var found = 0
        var lastEmit = ContinuousClock.now

        try await withThrowingTaskGroup(of: (matches: [FileItem], subfolders: [URL]).self) { group in
            var running = 0
            while !pending.isEmpty || running > 0 {
                try Task.checkCancellation()
                while running < width, let next = pending.popLast() {
                    running += 1
                    group.addTask { try Self.scan(next, matcher: matcher, query: query, devices: devices) }
                }
                guard let result = try await group.next() else { break }
                running -= 1
                pending.append(contentsOf: result.subfolders)
                let room = Self.searchResultLimit - found
                batch.append(contentsOf: result.matches.prefix(room))
                found += min(room, result.matches.count)
                if found >= Self.searchResultLimit {
                    group.cancelAll()
                    break
                }
                if batch.count >= batchSize || (!batch.isEmpty && ContinuousClock.now - lastEmit > .milliseconds(100)) {
                    emit(batch)
                    batch = []
                    lastEmit = .now
                }
            }
        }
        if !batch.isEmpty { emit(batch) }
    }

    /// Lists one folder: its matching items, and the subfolders to visit next.
    private static func scan(
        _ folder: URL, matcher: SearchMatcher,
        query: SearchQuery, devices: Set<dev_t>
    ) throws -> (matches: [FileItem], subfolders: [URL]) {
        try Task.checkCancellation()
        var options: FileManager.DirectoryEnumerationOptions = []
        if !query.includeHidden { options.insert(.skipsHiddenFiles) }
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: FileItem.resourceKeys, options: options)
        else {
            // Folders we can't read are skipped, as Finder does.
            return ([], [])
        }
        var matches: [FileItem] = []
        var subfolders: [URL] = []
        for (index, url) in urls.enumerated() {
            if index % 512 == 0 { try Task.checkCancellation() }
            guard let item = try? FileItem(url: url) else { continue }
            if query.includeSubfolders, item.isDirectory, !item.isSymbolicLink,
                !item.isPackage || query.includePackages, url.path != dataVolumePath,
                let device = lstatInfo(url.path)?.st_dev, devices.contains(device)
            {
                // Mount points of other disks, shares and images are not entered.
                subfolders.append(url)
            }
            guard matcher.matches(item) else { continue }
            if let tag = query.tag {
                let tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
                guard tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { continue }
            }
            matches.append(item)
        }
        return (matches, subfolders)
    }
}
