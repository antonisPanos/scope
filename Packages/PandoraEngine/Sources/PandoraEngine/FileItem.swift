import Foundation

/// One entry of a folder listing, as a value the UI can hold without touching disk.
public struct FileItem: Sendable, Hashable, Identifiable {
    public var id: URL { url }

    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isPackage: Bool
    public let isHidden: Bool
    /// Logical size in bytes; nil for folders.
    public let size: Int64?
    public let modified: Date?

    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .isHiddenKey, .fileSizeKey, .contentModificationDateKey,
    ]

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: Set(Self.resourceKeys))
        self.url = url
        self.name = values.name ?? url.lastPathComponent
        self.isDirectory = values.isDirectory ?? false
        self.isSymbolicLink = values.isSymbolicLink ?? false
        self.isPackage = values.isPackage ?? false
        self.isHidden = values.isHidden ?? url.lastPathComponent.hasPrefix(".")
        self.size = (values.isDirectory ?? false) ? nil : values.fileSize.map(Int64.init)
        self.modified = values.contentModificationDate
    }
}
