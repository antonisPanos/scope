import CoreServices
import Foundation
import Synchronization

/// Live change notifications for one folder.
///
/// Only changes to the folder's direct children are reported. Local disks
/// are watched through FSEvents, coalesced over `latency`. Network shares
/// are polled instead, since FSEvents doesn't hear about changes other
/// machines make there. The stream is created for folders on screen and ends
/// when its consumer stops iterating, so nothing is watched in the background.
public enum FolderWatcher {
    /// How a folder is watched.
    public enum Backend: Sendable, Equatable {
        /// FSEvents: immediate, for local disks.
        case fsEvents
        /// Comparing the folder's entries every `interval`, for file systems
        /// that send no events, such as SMB and NFS shares.
        case polling(interval: Duration)

        /// How often network shares are polled.
        public static let networkInterval: Duration = .seconds(3)

        /// FSEvents on local disks, polling on network ones. Decided from the
        /// kernel's mount table without waiting on the disk.
        public static func automatic(for folder: URL, mounts: MountTable = MountTable()) -> Backend {
            mounts.isNetwork(folder.path) ? .polling(interval: networkInterval) : .fsEvents
        }
    }

    /// That something in the folder changed.
    public static func changes(
        in folder: URL, pathGuard: PathGuard, latency: TimeInterval = 0.25, backend: Backend? = nil
    ) throws -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        try watch(folder, pathGuard: pathGuard, latency: latency, backend: backend, signal: continuation) { _ in }
        return stream
    }

    /// What changed in the folder: the names of the children that were
    /// added, removed, renamed or modified, or `.everything` when FSEvents
    /// can't say (events were dropped, or the folder itself moved).
    ///
    /// Changes that arrive while the consumer is busy are merged, so it
    /// never falls behind and never misses a name.
    public static func events(
        in folder: URL, pathGuard: PathGuard, latency: TimeInterval = 0.25, backend: Backend? = nil
    ) throws -> FolderEvents {
        let (signals, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let pending = PendingChange()
        try watch(folder, pathGuard: pathGuard, latency: latency, backend: backend, signal: continuation) { change in
            pending.add(change)
        }
        return FolderEvents(signals: signals, pending: pending)
    }

    /// Starts watching `folder`. Each change is first passed to `record`,
    /// then `signal` is yielded; watching stops when `signal` terminates.
    private static func watch(
        _ folder: URL, pathGuard: PathGuard, latency: TimeInterval, backend: Backend?,
        signal continuation: AsyncStream<Void>.Continuation,
        record: @escaping @Sendable (FolderChange) -> Void
    ) throws {
        let resolved = try pathGuard.checkTarget(folder)
        let report: @Sendable (FolderChange) -> Void = { change in
            record(change)
            continuation.yield()
        }
        switch backend ?? .automatic(for: resolved) {
        case .fsEvents:
            watchEvents(resolved, latency: latency, signal: continuation, report: report)
        case .polling(let interval):
            let task = Task.detached(executorPreference: IOExecutor.shared, priority: .utility) {
                await poll(resolved.path, every: interval, report: report)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Compares the folder's entries every `interval` until cancelled.
    private static func poll(
        _ folder: String, every interval: Duration, report: @Sendable (FolderChange) -> Void
    ) async {
        var previous = FolderSnapshot.read(folder)
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            let current = FolderSnapshot.read(folder)
            if let change = FolderSnapshot.change(from: previous, to: current) { report(change) }
            previous = current
        }
    }

    private static func watchEvents(
        _ resolved: URL, latency: TimeInterval,
        signal continuation: AsyncStream<Void>.Continuation,
        report: @escaping @Sendable (FolderChange) -> Void
    ) {
        let box = WatcherBox(folder: resolved.path, report: report)

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

/// A folder's entries as polling compares them: each name with what changes
/// when the item does. Nil when the folder can't be read.
struct FolderSnapshot {
    struct Entry: Equatable {
        var inode: UInt64
        var modified: Int64
        var changed: Int64
        var size: Int64
    }

    static func read(_ folder: String) -> [String: Entry]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
        var entries: [String: Entry] = [:]
        entries.reserveCapacity(names.count)
        for name in names {
            guard let info = FileEngine.lstatInfo(folder + "/" + name) else { continue }
            entries[name] = Entry(
                inode: UInt64(info.st_ino),
                modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                changed: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec),
                size: Int64(info.st_size))
        }
        return entries
    }

    /// The change between two snapshots: the names added, removed or
    /// changed, `.everything` when the folder appeared or went away, or nil.
    static func change(from old: [String: Entry]?, to new: [String: Entry]?) -> FolderChange? {
        guard let old, let new else { return (old == nil) == (new == nil) ? nil : .everything }
        var names: Set<String> = []
        for (name, entry) in new where old[name] != entry { names.insert(name) }
        for name in old.keys where new[name] == nil { names.insert(name) }
        return names.isEmpty ? nil : .children(names)
    }
}
