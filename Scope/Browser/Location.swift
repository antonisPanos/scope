import Foundation
import ScopeEngine
import Synchronization

/// What a browser tab shows: a folder, or a virtual list of items.
enum Location: Hashable, Sendable {
    case folder(URL)
    case recents
    case tag(String)
    /// Search results for a query, under a folder.
    case search(SearchQuery, in: URL)

    var folderURL: URL? {
        if case .folder(let url) = self { return url }
        return nil
    }

    /// The folder a search looks in, or the folder on screen.
    var searchRoot: URL? {
        switch self {
        case .folder(let url), .search(_, let url): url
        default: nil
        }
    }

    var isSearch: Bool {
        if case .search = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .folder(let url):
            url.path == "/" ? (Volumes.rootName ?? "Macintosh HD") : url.lastPathComponent
        case .recents: "Recents"
        case .tag(let tag): tag
        case .search(let query, let folder):
            query.text.isEmpty
                ? "Search in \(folder.lastPathComponent)" : "“\(query.text)” in \(folder.lastPathComponent)"
        }
    }

    var symbolName: String {
        switch self {
        case .folder: "folder"
        case .recents: "clock"
        case .tag: "tag"
        case .search: "magnifyingglass"
        }
    }
}

extension Volumes {
    /// Name of the startup disk, for showing "/" the way Finder does.
    private static let rootNameCache = Mutex<String?>(nil)
    static var rootName: String? { rootNameCache.withLock { $0 } }

    static func updateRootName(from volumes: [VolumeInfo]) {
        rootNameCache.withLock { $0 = volumes.first { $0.isRootVolume }?.name }
    }
}
