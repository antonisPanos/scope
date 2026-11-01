import Foundation
import UniformTypeIdentifiers

/// One entry of a folder listing, as a value the UI can hold without touching disk.
public struct FileItem: Sendable, Hashable, Identifiable {
    public var id: URL { url }

    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isAlias: Bool
    public let isPackage: Bool
    public let isHidden: Bool
    /// Logical size in bytes; nil for folders.
    public let size: Int64?
    public let modified: Date?
    public let created: Date?
    public let added: Date?
    /// The type's description as Finder shows it ("PDF document", "Folder").
    public let kind: String

    /// Keys prefetched for every listed item. Finder tags are left out on
    /// purpose: they live in an extended attribute, and reading it for every
    /// item makes a big folder list three times slower. Use
    /// `FileEngine.tags(for:)` for the rows on screen instead.
    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey,
        .isHiddenKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
        .addedToDirectoryDateKey,
    ]

    public init(url: URL) throws {
        let values = try url.resourceValues(forKeys: Set(Self.resourceKeys))
        self.url = url
        self.name = values.name ?? url.lastPathComponent
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        self.isDirectory = isDirectory
        self.isSymbolicLink = values.isSymbolicLink ?? false
        // Symlinks also report isAliasFile; only Finder aliases count here.
        self.isAlias = (values.isAliasFile ?? false) && !(values.isSymbolicLink ?? false)
        self.isPackage = isPackage
        self.isHidden = values.isHidden ?? url.lastPathComponent.hasPrefix(".")
        self.size = isDirectory && !isPackage ? nil : values.fileSize.map(Int64.init)
        self.modified = values.contentModificationDate
        self.created = values.creationDate
        self.added = values.addedToDirectoryDate
        if values.isSymbolicLink == true {
            self.kind = "Symbolic link"
        } else if isDirectory && !isPackage {
            self.kind = "Folder"
        } else {
            self.kind = KindCache.shared.kind(of: url, isPackage: isPackage)
        }
    }

    /// Whether the browser opens this item as a folder (packages open as files).
    public var isBrowsableFolder: Bool { isDirectory && !isPackage }
}

/// Kind descriptions by file extension. The first file with each extension
/// is asked for its kind as Finder words it ("Plain Text Document"); every
/// later file with that extension reuses the answer, which keeps big folders
/// fast.
final class KindCache: @unchecked Sendable {
    static let shared = KindCache()

    private let lock = NSLock()
    private var kinds: [String: String] = [:]

    func kind(of url: URL, isPackage: Bool) -> String {
        let pathExtension = url.pathExtension
        let key = (isPackage ? "package:" : "") + pathExtension.lowercased()
        lock.lock()
        let cached = kinds[key]
        lock.unlock()
        if let cached { return cached }

        let kind = (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription)
            ?? UTType(filenameExtension: pathExtension, conformingTo: isPackage ? .package : .data)?.localizedDescription
            ?? (pathExtension.isEmpty ? "Document" : "\(pathExtension.uppercased()) file")
        lock.lock()
        kinds[key] = kind
        lock.unlock()
        return kind
    }
}
