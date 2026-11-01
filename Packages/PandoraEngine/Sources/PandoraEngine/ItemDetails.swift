import AVFoundation
import Foundation
import ImageIO

/// Extra facts about one item for the preview pane, gathered on demand.
public struct ItemDetails: Sendable, Equatable {
    public var item: FileItem
    /// Items directly inside a folder.
    public var folderItemCount: Int?
    public var lastOpened: Date?
    public var tags: [String] = []
    /// Where a symlink or alias points.
    public var linkTarget: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var cameraModel: String?
    public var dateTaken: String?
    public var duration: TimeInterval?
}

extension FileEngine {
    /// Reads what the preview pane shows for one item. Images are read for
    /// their dimensions and camera data, audio and video for their length,
    /// folders for how many items they hold.
    public func details(for url: URL) async throws -> ItemDetails {
        let location = try pathGuard.checkLocation(url)
        let item = try FileItem(url: location)
        var details = ItemDetails(item: item)

        let values = try? location.resourceValues(forKeys: [.tagNamesKey, .contentAccessDateKey])
        details.tags = values?.tagNames ?? []
        details.lastOpened = Self.lastUsedDate(location) ?? values?.contentAccessDate

        if item.isSymbolicLink {
            details.linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: location.path)
        } else if item.isAlias {
            details.linkTarget = (try? URL(resolvingAliasFileAt: location, options: [.withoutUI, .withoutMounting]))?.path
        }

        if item.isBrowsableFolder && !item.isSymbolicLink {
            details.folderItemCount = (try? FileManager.default.contentsOfDirectory(atPath: location.path))?
                .filter { !$0.hasPrefix(".") }.count
            return details
        }
        guard !item.isSymbolicLink, !item.isAlias else { return details }

        try Task.checkCancellation()
        if let source = CGImageSourceCreateWithURL(location as CFURL, nil),
           CGImageSourceGetCount(source) > 0,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            details.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
            details.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let make = tiff?[kCGImagePropertyTIFFMake] as? String
            let model = tiff?[kCGImagePropertyTIFFModel] as? String
            details.cameraModel = [make, model].compactMap { $0 }.joined(separator: " ").nilIfEmpty
            details.dateTaken = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
        }

        try Task.checkCancellation()
        let kind = item.kind.lowercased()
        let mediaExtensions = ["mp3", "m4a", "wav", "aiff", "aac", "flac", "mov", "mp4", "m4v"]
        if ["audio", "movie", "video", "mpeg"].contains(where: kind.contains)
            || mediaExtensions.contains(location.pathExtension.lowercased()) {
            let asset = AVURLAsset(url: location)
            if let duration = try? await asset.load(.duration), duration.isNumeric {
                details.duration = duration.seconds
            }
        }
        return details
    }

    /// The "last opened" date Finder shows, kept by macOS in an extended attribute.
    private static func lastUsedDate(_ url: URL) -> Date? {
        var time = timespec()
        let size = getxattr(url.path, "com.apple.lastuseddate#PS", &time, MemoryLayout<timespec>.size, 0, XATTR_NOFOLLOW)
        guard size == MemoryLayout<timespec>.size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
