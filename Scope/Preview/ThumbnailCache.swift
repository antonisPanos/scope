import AppKit
import ScopeEngine
import QuickLookThumbnailing

/// Thumbnails for the icon grid and gallery, made by Quick Look (which keeps
/// its own shared cache on disk, so Scope writes none). Scope holds at
/// most 64 MB of them in memory; the least recently used go first. Only items
/// on screen ask for one.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    static let didLoad = Notification.Name("ScopeThumbnailDidLoad")
    static let memoryLimit = 64 * 1024 * 1024

    private let cache = NSCache<NSString, NSImage>()
    private var pending: [NSString: QLThumbnailGenerator.Request] = [:]
    private var failed: Set<NSString> = []

    private init() {
        cache.totalCostLimit = Self.memoryLimit
    }

    /// The cached thumbnail, or nil while one is made in the background. A
    /// `didLoad` notification (object: the item's URL) follows when it's ready.
    func thumbnail(for item: FileItem, pointSize: CGFloat, scale: CGFloat, pathGuard: PathGuard) -> NSImage? {
        // Folders and links have no content to show; their icons are better.
        guard !item.isBrowsableFolder, !item.isSymbolicLink, !item.isAlias else { return nil }
        let bucket = Self.bucket(for: pointSize)
        let key = Self.key(item, bucket) as NSString
        if let image = cache.object(forKey: key) { return image }
        guard pending[key] == nil, !failed.contains(key), pathGuard.permits(item.url) else { return nil }

        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: bucket, height: bucket),
                                                   scale: scale, representationTypes: .thumbnail)
        pending[key] = request
        let url = item.url
        let keyString = key as String
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation.map { Thumbnail(image: $0.nsImage, pixels: Int($0.cgImage.width * $0.cgImage.height * 4)) }
            Task { @MainActor in
                ThumbnailCache.shared.finish(key: keyString as NSString, url: url, thumbnail: image)
            }
        }
        return nil
    }

    /// Stops making thumbnails nobody is waiting for any more (a closed tab).
    func cancelAll() {
        for request in pending.values { QLThumbnailGenerator.shared.cancel(request) }
        pending = [:]
    }

    private func finish(key: NSString, url: URL, thumbnail: Thumbnail?) {
        pending[key] = nil
        guard let thumbnail else {
            failed.insert(key)
            return
        }
        cache.setObject(thumbnail.image, forKey: key, cost: thumbnail.pixels)
        NotificationCenter.default.post(name: Self.didLoad, object: url)
    }

    /// Thumbnails come in a few sizes so a slider drag doesn't make dozens.
    private static func bucket(for pointSize: CGFloat) -> CGFloat {
        [32, 64, 128, 256, 512].first { $0 >= pointSize } ?? 512
    }

    private static func key(_ item: FileItem, _ bucket: CGFloat) -> String {
        "\(item.url.path)|\(Int(bucket))|\(item.modified?.timeIntervalSince1970 ?? 0)"
    }
}

/// Carries a finished thumbnail from Quick Look's queue to the main thread.
private struct Thumbnail: @unchecked Sendable {
    let image: NSImage
    let pixels: Int
}
