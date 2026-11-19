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
    /// Owner, group and mode as `ls -l` shows them ("rwxr-xr-x").
    public var owner: String?
    public var group: String?
    public var permissions: String?
    public var isLocked = false
    public var volumeName: String?
}

/// The total size of a folder and everything in it.
public struct FolderSize: Sendable, Equatable {
    /// Sum of the files' sizes.
    public var bytes: Int64 = 0
    /// Space the files take on disk.
    public var allocatedBytes: Int64 = 0
    /// Files and folders inside, at any depth.
    public var items = 0
    /// Some descendants or required size metadata could not be read.
    public var isIncomplete = false
}

extension FileEngine {
    /// Reads what the preview pane shows for one item. Images are read for
    /// their dimensions and camera data, audio and video for their length,
    /// folders optionally for how many items they hold.
    public func details(for url: URL, includeFolderItemCount: Bool = true) async throws -> ItemDetails {
        return try await onIOThreads {
            try Task.checkCancellation()
            let location = try pathGuard.checkLocation(url)
            let item = try FileItem(url: location)
            var details = ItemDetails(item: item)

            let values = try? location.resourceValues(forKeys: [
                .contentAccessDateKey, .volumeLocalizedNameKey,
            ])
            details.tags = (try? FinderTags.names(at: location)) ?? []
            details.volumeName = values?.volumeLocalizedName
            if let info = Self.lstatInfo(location.path) {
                details.permissions = Self.modeString(info.st_mode)
                details.isLocked = info.st_flags & UInt32(UF_IMMUTABLE) != 0
                details.owner = getpwuid(info.st_uid).map { String(cString: $0.pointee.pw_name) } ?? "\(info.st_uid)"
                details.group = getgrgid(info.st_gid).map { String(cString: $0.pointee.gr_name) } ?? "\(info.st_gid)"
            }
            details.lastOpened = Self.lastUsedDate(location) ?? values?.contentAccessDate

            if item.isSymbolicLink {
                details.linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: location.path)
            } else if item.isAlias {
                details.linkTarget =
                    (try? URL(resolvingAliasFileAt: location, options: [.withoutUI, .withoutMounting]))?.path
            }

            if item.isBrowsableFolder && !item.isSymbolicLink {
                if includeFolderItemCount {
                    try Task.checkCancellation()
                    details.folderItemCount =
                        (try? FileManager.default.contentsOfDirectory(atPath: location.path))?
                        .filter { !$0.hasPrefix(".") }.count
                }
                try Task.checkCancellation()
                return details
            }
            guard !item.isSymbolicLink, !item.isAlias else { return details }

            try Task.checkCancellation()
            if let source = CGImageSourceCreateWithURL(location as CFURL, nil),
                CGImageSourceGetCount(source) > 0,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            {
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
                || mediaExtensions.contains(location.pathExtension.lowercased())
            {
                let asset = AVURLAsset(url: location)
                if let duration = try? await asset.load(.duration), duration.isNumeric {
                    details.duration = duration.seconds
                }
            }
            return details
        }
    }

    /// Adds up a folder's contents on demand, without following symlinks.
    /// Reports running totals, including incomplete results for unreadable descendants.
    /// Cancellation is checked between I/O calls; a blocked filesystem call must return first.
    public func folderSize(of url: URL, progress: (@Sendable (FolderSize) -> Void)? = nil) async throws -> FolderSize {
        return try await onIOThreads {
            let folder = try readableCountRoot(url)
            let keys: [URLResourceKey] = [
                .fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey,
            ]
            let keySet = Set(keys)
            var total = FolderSize()
            var rootError: Error?
            guard
                let enumerator = FileManager.default.enumerator(
                    at: folder, includingPropertiesForKeys: keys, options: [],
                    errorHandler: { failedURL, error in
                        if failedURL.path == folder.path { rootError = error }
                        total.isIncomplete = true
                        return rootError == nil && !Task.isCancelled
                    })
            else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: folder.path]) }
            while true {
                try Task.checkCancellation()
                guard let next = enumerator.nextObject() as? URL else { break }
                try Task.checkCancellation()
                total.items += 1
                do {
                    let location = try pathGuard.checkLocation(next)
                    try folderSizeEntryWillRead?(location)
                    try Task.checkCancellation()
                    // Keep the enumerator's prefetched metadata when canonicalization
                    // did not change the URL, rather than reading every item twice.
                    let resourceURL = location.path == next.path ? next : location
                    let values = try resourceURL.resourceValues(forKeys: keySet)
                    try Task.checkCancellation()
                    if let isDirectory = values.isDirectory, let isLink = values.isSymbolicLink {
                        if !isDirectory && !isLink {
                            total.bytes += Int64(values.fileSize ?? 0)
                            total.allocatedBytes += Int64(values.totalFileAllocatedSize ?? 0)
                            if values.fileSize == nil || values.totalFileAllocatedSize == nil {
                                total.isIncomplete = true
                            }
                        }
                    } else {
                        total.isIncomplete = true
                    }
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    total.isIncomplete = true
                    enumerator.skipDescendants()
                }
                if total.items.isMultiple(of: 500) {
                    try Task.checkCancellation()
                    progress?(total)
                }
            }
            try Task.checkCancellation()
            if let rootError { throw rootError }
            // An enumerator may have cached its last entries before a volume
            // disappeared. Don't publish a successful result for a lost root.
            _ = try readableCountRoot(folder)
            progress?(total)
            try Task.checkCancellation()
            return total
        }
    }

    private func readableCountRoot(_ url: URL) throws -> URL {
        try Task.checkCancellation()
        let folder = try pathGuard.checkTarget(url)
        try Task.checkCancellation()
        // Validate readability without materializing the immediate children.
        guard let directory = opendir(folder.path) else {
            throw FileEngineError.posix("Count folder", folder.path)
        }
        closedir(directory)
        try Task.checkCancellation()
        return folder
    }

    static func modeString(_ mode: mode_t) -> String {
        let bits: [(mode_t, Character)] = [
            (S_IRUSR, "r"), (S_IWUSR, "w"), (S_IXUSR, "x"), (S_IRGRP, "r"), (S_IWGRP, "w"),
            (S_IXGRP, "x"), (S_IROTH, "r"), (S_IWOTH, "w"), (S_IXOTH, "x"),
        ]
        return String(bits.map { mode & $0.0 != 0 ? $0.1 : "-" })
    }

    /// The "last opened" date Finder shows, kept by macOS in an extended attribute.
    private static func lastUsedDate(_ url: URL) -> Date? {
        var time = timespec()
        let size = getxattr(
            url.path, "com.apple.lastuseddate#PS", &time, MemoryLayout<timespec>.size, 0, XATTR_NOFOLLOW)
        guard size == MemoryLayout<timespec>.size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
