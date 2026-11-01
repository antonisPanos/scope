import AppKit
import QuickLookThumbnailing
import ScopeEngine

/// Thumbnails for the icon grid and gallery, made by Quick Look (which keeps
/// its own shared cache on disk, so Scope writes none). Scope holds at
/// most 64 MB of them in memory; the least recently used go first. Only items
/// on screen ask for one.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    static let didLoad = Notification.Name("ScopeThumbnailDidLoad")
    static let memoryLimit = 64 * 1024 * 1024

    /// A failed thumbnail is tried again after this long, in case the file
    /// was still being written or its disk was asleep.
    static let retryAfter: TimeInterval = 60
    /// At most this many failures are remembered; the oldest go first.
    static let failureLimit = 2_000

    private let cache = NSCache<NSString, NSImage>()
    private var pending: [NSString: Pending] = [:]
    private var failed: [NSString: Date] = [:]

    /// A thumbnail being made, and the views waiting for it. The request is
    /// nil while the path guard check runs in the background.
    private struct Pending {
        var owners: Set<ObjectIdentifier>
        var request: QLThumbnailGenerator.Request?
    }

    private init() {
        cache.totalCostLimit = Self.memoryLimit
    }

    /// The cached thumbnail. While one of the right size is made in the
    /// background, a cached one of another size stands in, so a zoom shows
    /// the old thumbnail scaled rather than flashing back to the file icon;
    /// nil when there is none. A `didLoad` notification (object: the item's
    /// URL) follows when the right size is ready. `owner` is the view asking;
    /// `cancelRequests(of:)` stops its requests.
    func thumbnail(
        for item: FileItem, pointSize: CGFloat, scale: CGFloat, pathGuard: PathGuard, owner: ObjectIdentifier
    ) -> NSImage? {
        // Folders and links have no content to show; their icons are better.
        guard !item.isBrowsableFolder, !item.isSymbolicLink, !item.isAlias else { return nil }
        let bucket = Self.bucket(for: pointSize)
        let key = Self.key(item, bucket) as NSString
        if let image = cache.object(forKey: key) { return image }
        let standIn = standIn(for: item, bucket: bucket)
        if pending[key] != nil {
            pending[key]?.owners.insert(owner)
            return standIn
        }
        if let failure = failed[key] {
            guard Date().timeIntervalSince(failure) > Self.retryAfter else { return standIn }
            failed[key] = nil
        }

        pending[key] = Pending(owners: [owner], request: nil)
        let url = item.url
        let keyString = key as String
        let size = CGSize(width: bucket, height: bucket)
        // The guard resolves the path, which is disk work: never on the main thread.
        Task.detached(priority: .utility) {
            let permitted = pathGuard.permits(url)
            await MainActor.run {
                ThumbnailCache.shared.start(
                    key: keyString as NSString, url: url, size: size, scale: scale, permitted: permitted)
            }
        }
        return standIn
    }

    /// A cached thumbnail of the item at another size: the next larger one,
    /// which scales down sharply, or else the largest smaller one.
    private func standIn(for item: FileItem, bucket: CGFloat) -> NSImage? {
        let larger = Self.buckets.filter { $0 > bucket }
        let smaller = Self.buckets.filter { $0 < bucket }.reversed()
        for other in larger + smaller {
            if let image = cache.object(forKey: Self.key(item, other) as NSString) { return image }
        }
        return nil
    }

    /// Stops making the thumbnails only `owner` was waiting for (a closed
    /// tab or view). Other views' requests keep going.
    func cancelRequests(of owner: ObjectIdentifier) {
        for (key, var entry) in pending where entry.owners.contains(owner) {
            entry.owners.remove(owner)
            if entry.owners.isEmpty {
                if let request = entry.request { QLThumbnailGenerator.shared.cancel(request) }
                pending[key] = nil
            } else {
                pending[key] = entry
            }
        }
    }

    private func start(key: NSString, url: URL, size: CGSize, scale: CGFloat, permitted: Bool) {
        // Gone when every view that asked was closed while the guard was checked.
        guard pending[key] != nil, pending[key]?.request == nil else { return }
        guard permitted else {
            pending[key] = nil
            recordFailure(key)
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        pending[key]?.request = request
        let requestID = ObjectIdentifier(request)
        let keyString = key as String
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation.map {
                Thumbnail(image: $0.nsImage, pixels: Int($0.cgImage.width * $0.cgImage.height * 4))
            }
            Task { @MainActor in
                ThumbnailCache.shared.finish(key: keyString, requestID: requestID, url: url, thumbnail: image)
            }
        }
    }

    private func finish(key keyString: String, requestID: ObjectIdentifier, url: URL, thumbnail: Thumbnail?) {
        let key = keyString as NSString
        // A cancelled request also ends here, with an error. It isn't a
        // failure: the item gets a fresh request when it's shown again.
        let isCurrent = pending[key]?.request.map { ObjectIdentifier($0) } == requestID
        if isCurrent { pending[key] = nil }
        guard let thumbnail else {
            if isCurrent { recordFailure(key) }
            return
        }
        cache.setObject(thumbnail.image, forKey: key, cost: thumbnail.pixels)
        NotificationCenter.default.post(name: Self.didLoad, object: url)
    }

    private func recordFailure(_ key: NSString) {
        if failed.count >= Self.failureLimit {
            let oldest = failed.sorted { $0.value < $1.value }.prefix(Self.failureLimit / 4)
            for (old, _) in oldest { failed[old] = nil }
        }
        failed[key] = Date()
    }

    /// Thumbnails come in a few sizes so a slider drag doesn't make dozens.
    private static let buckets: [CGFloat] = [32, 64, 128, 256, 512]

    private static func bucket(for pointSize: CGFloat) -> CGFloat {
        buckets.first { $0 >= pointSize } ?? 512
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
