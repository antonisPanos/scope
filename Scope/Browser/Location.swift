import Foundation
import ScopeEngine

/// What a browser tab shows: a folder, or a virtual list of items.
enum Location: Hashable, Sendable {
    case folder(URL)
    case recents
    case tag(String)

    var folderURL: URL? {
        if case .folder(let url) = self { return url }
        return nil
    }

    var title: String {
        switch self {
        case .folder(let url):
            url.path == "/" ? (Volumes.rootName ?? "Macintosh HD") : url.lastPathComponent
        case .recents: "Recents"
        case .tag(let tag): tag
        }
    }

    var symbolName: String {
        switch self {
        case .folder: "folder"
        case .recents: "clock"
        case .tag: "tag"
        }
    }
}

extension Volumes {
    /// Name of the startup disk, for showing "/" the way Finder does.
    static let rootName: String? = mounted().first { $0.isRootVolume }?.name
}
