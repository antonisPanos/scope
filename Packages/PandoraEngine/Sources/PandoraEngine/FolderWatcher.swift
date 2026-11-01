import CoreServices
import Foundation

/// Live change notifications for one folder, through FSEvents.
///
/// Only changes to the folder's direct children are reported, coalesced over
/// `latency`. The stream is created for folders on screen and ends when its
/// consumer stops iterating, so nothing is watched in the background.
public enum FolderWatcher {
    public static func changes(in folder: URL, pathGuard: PathGuard, latency: TimeInterval = 0.25) throws -> AsyncStream<Void> {
        let resolved = try pathGuard.checkTarget(folder)
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let box = WatcherBox(folder: resolved.path, continuation: continuation)

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                if let info { Unmanaged<WatcherBox>.fromOpaque(info).release() }
            },
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<WatcherBox>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: flags, count: count))
            box.handle(paths: paths, flags: flags)
        }

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let eventStream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [resolved.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            continuation.finish()
            return stream
        }

        let queue = DispatchQueue(label: "com.antonispanos.pandora.FolderWatcher")
        FSEventStreamSetDispatchQueue(eventStream, queue)
        FSEventStreamStart(eventStream)

        let handle = StreamHandle(eventStream)
        continuation.onTermination = { _ in
            queue.async { handle.stop() }
        }
        return stream
    }
}

private final class WatcherBox: @unchecked Sendable {
    let folder: String
    let continuation: AsyncStream<Void>.Continuation

    init(folder: String, continuation: AsyncStream<Void>.Continuation) {
        self.folder = folder
        self.continuation = continuation
    }

    func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        for (path, flag) in zip(paths, flags) {
            let parent = (path as NSString).deletingLastPathComponent
            let rootChanged = flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0
            let rescan = flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
            if parent == folder || path == folder || rootChanged || rescan {
                continuation.yield()
                return
            }
        }
    }
}

/// Owns the FSEventStream; touched only on the watcher's queue.
private final class StreamHandle: @unchecked Sendable {
    private var stream: FSEventStreamRef?

    init(_ stream: FSEventStreamRef) {
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
