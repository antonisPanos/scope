import CoreServices
import Foundation
import Synchronization

/// Live change notifications for one folder, through FSEvents.
///
/// Only changes to the folder's direct children are reported, coalesced over
/// `latency`. The stream is created for folders on screen and ends when its
/// consumer stops iterating, so nothing is watched in the background.
public enum FolderWatcher {
    /// That something in the folder changed.
    public static func changes(
        in folder: URL, pathGuard: PathGuard, latency: TimeInterval = 0.25
    ) throws -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        try watch(folder, pathGuard: pathGuard, latency: latency, signal: continuation) { _ in }
        return stream
    }

    /// What changed in the folder: the names of the children that were
    /// added, removed, renamed or modified, or `.everything` when FSEvents
    /// can't say (events were dropped, or the folder itself moved).
    ///
    /// Changes that arrive while the consumer is busy are merged, so it
    /// never falls behind and never misses a name.
    public static func events(
        in folder: URL, pathGuard: PathGuard, latency: TimeInterval = 0.25
    ) throws -> FolderEvents {
        let (signals, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let pending = PendingChange()
        try watch(folder, pathGuard: pathGuard, latency: latency, signal: continuation) { change in
            pending.add(change)
        }
        return FolderEvents(signals: signals, pending: pending)
    }

    /// Starts FSEvents on `folder`. Each change is first passed to `record`,
    /// then `signal` is yielded; the stream stops when `signal` terminates.
    private static func watch(
        _ folder: URL, pathGuard: PathGuard, latency: TimeInterval,
        signal continuation: AsyncStream<Void>.Continuation,
        record: @escaping @Sendable (FolderChange) -> Void
    ) throws {
        let resolved = try pathGuard.checkTarget(folder)
        let box = WatcherBox(folder: resolved.path) { change in
            record(change)
            continuation.yield()
        }

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

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard
            let eventStream = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, [resolved.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            // The stream never took the box, so its release callback won't run.
            Unmanaged.passUnretained(box).release()
            continuation.finish()
            return
        }

        let queue = DispatchQueue(label: "com.antonispanos.scope.FolderWatcher")
        FSEventStreamSetDispatchQueue(eventStream, queue)
        FSEventStreamStart(eventStream)

        let handle = StreamHandle(eventStream)
        continuation.onTermination = { _ in
            queue.async { handle.stop() }
        }
    }

    /// The change FSEvents reports for `paths` in `folder`, or nil when none
    /// of them is about the folder's direct children.
    static func change(in folder: String, paths: [String], flags: [FSEventStreamEventFlags]) -> FolderChange? {
        var names: Set<String> = []
        for (path, flag) in zip(paths, flags) {
            let rootChanged = flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0
            let rescan = flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
            if rootChanged || rescan { return .everything }
            if path == folder {
                // The folder's own details don't change its listing, unless it went away.
                let gone = UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
                if flag & gone != 0 { return .everything }
                continue
            }
            if (path as NSString).deletingLastPathComponent == folder {
                names.insert((path as NSString).lastPathComponent)
            }
        }
        return names.isEmpty ? nil : .children(names)
    }
}

/// What changed in a watched folder.
public enum FolderChange: Sendable, Equatable {
    /// These direct children were added, removed, renamed or modified.
    case children(Set<String>)
    /// Anything may have changed: list the folder again.
    case everything

    /// Both changes as one.
    public func merged(with other: FolderChange) -> FolderChange {
        switch (self, other) {
        case (.children(let a), .children(let b)): .children(a.union(b))
        default: .everything
        }
    }
}

/// The changes in a watched folder, as `FolderWatcher.events(in:)` reports
/// them. Changes that arrive while the consumer is busy wait merged into one.
public struct FolderEvents: AsyncSequence, Sendable {
    public typealias Element = FolderChange
    public typealias Failure = Never

    let signals: AsyncStream<Void>
    let pending: PendingChange

    public struct AsyncIterator: AsyncIteratorProtocol {
        var signals: AsyncStream<Void>.AsyncIterator
        let pending: PendingChange

        public mutating func next() async -> FolderChange? {
            while await signals.next() != nil {
                // A change already taken with an earlier signal leaves nothing.
                if let change = pending.take() { return change }
            }
            return nil
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(signals: signals.makeAsyncIterator(), pending: pending)
    }
}

/// Changes reported but not yet taken, merged into one.
final class PendingChange: Sendable {
    private let waiting = Mutex<FolderChange?>(nil)

    func add(_ change: FolderChange) {
        waiting.withLock { $0 = $0.map { $0.merged(with: change) } ?? change }
    }

    func take() -> FolderChange? {
        waiting.withLock { waiting in
            defer { waiting = nil }
            return waiting
        }
    }
}

private final class WatcherBox: @unchecked Sendable {
    let folder: String
    let report: @Sendable (FolderChange) -> Void

    init(folder: String, report: @escaping @Sendable (FolderChange) -> Void) {
        self.folder = folder
        self.report = report
    }

    func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        if let change = FolderWatcher.change(in: folder, paths: paths, flags: flags) { report(change) }
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
