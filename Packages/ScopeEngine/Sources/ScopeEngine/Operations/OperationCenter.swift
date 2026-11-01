import Foundation

/// The queue every file operation goes through.
///
/// Operations on the same disk run one at a time, in order; operations on
/// different disks run side by side. Items in a running or cancelling
/// operation are locked: a new operation that touches them is refused.
/// Identical requests already waiting are merged. The UI reads `snapshots()`
/// about ten times a second and never waits on the work itself.
public actor OperationCenter {
    public enum State: Sendable, Equatable {
        case queued, running, paused, cancelling, done, failed(String), cancelled
    }

    public struct Snapshot: Sendable, Identifiable, Equatable {
        public let id: UUID
        public let title: String
        public let state: State
        public let progress: OperationProgress
        public let speed: Double?
        public let started: Date?
        public let finished: Date?
        public let queuePosition: Int?
        public let canUndo: Bool
        public let isUndo: Bool
        public let skippedEntries: [String]
        public let destinationFolder: URL?

        public var isActive: Bool {
            switch state {
            case .queued, .running, .paused, .cancelling: true
            default: false
            }
        }

        /// Seconds left, from the smoothed speed.
        public var timeRemaining: TimeInterval? {
            guard let speed, speed > 0, progress.bytesTotal > 0 else { return nil }
            return Double(progress.bytesTotal - progress.bytesDone) / speed
        }
    }

    private final class Entry {
        let id = UUID()
        let operation: FileOperation
        let control = OperationControl()
        let undo = UndoRecorder()
        let disk: dev_t
        var state: State = .queued
        var task: Task<Void, Never>?
        var started: Date?
        var finished: Date?
        var undone = false

        var isActive: Bool { state.isActive }

        var isUndoOperation: Bool {
            if case .undo = operation.kind { return true }
            return false
        }

        init(operation: FileOperation, disk: dev_t) {
            self.operation = operation
            self.disk = disk
        }
    }

    private let engine: FileEngine
    private let resolveConflict: ConflictResolver
    private var entries: [Entry] = []
    private var observers: [UUID: @Sendable () -> Void] = [:]
    /// Finished operations kept for the session, newest last.
    private let historyLimit = 50

    public init(engine: FileEngine, resolveConflict: @escaping ConflictResolver) {
        self.engine = engine
        self.resolveConflict = resolveConflict
    }

    // MARK: - Adding

    /// Queues an operation and returns its id. Throws `itemsBusy` when it
    /// touches items a running operation holds. An identical request that is
    /// still waiting or running is returned instead of queued twice.
    @discardableResult
    public func enqueue(_ operation: FileOperation) throws -> UUID {
        if let same = entries.first(where: { $0.operation == operation && ($0.state == .queued || $0.state == .running) }) {
            return same.id
        }
        let touched = Set(operation.touchedItems.map(\.standardizedFileURL.path))
        let busy = entries.filter { $0.state == .running || $0.state == .cancelling || $0.state == .paused }
            .flatMap { $0.operation.touchedItems }
            .filter { item in touched.contains { Self.overlaps($0, item.standardizedFileURL.path) } }
        if !busy.isEmpty {
            throw OperationError.itemsBusy(Array(Set(busy.map(\.lastPathComponent))).sorted())
        }
        let entry = Entry(operation: operation, disk: Self.disk(for: operation))
        entries.append(entry)
        trimHistory()
        schedule()
        notify()
        return entry.id
    }

    /// Queues the undo of a finished operation.
    @discardableResult
    public func undo(_ id: UUID) throws -> UUID? {
        guard let entry = entries.first(where: { $0.id == id }), !entry.isActive, !entry.undone else { return nil }
        let steps = entry.undo.recorded
        guard !steps.isEmpty else { return nil }
        entry.undone = true
        return try enqueue(FileOperation(.undo(UndoRecord(title: entry.operation.title, steps: steps))))
    }

    /// The most recent finished operation that can still be undone.
    public func lastUndoable() -> UUID? {
        entries.last { !$0.isActive && !$0.undone && !$0.undo.recorded.isEmpty && !$0.isUndoOperation }?.id
    }

    // MARK: - Control

    /// Cancels an operation. A running one stops between chunks; whatever it
    /// finished stays (and can be undone), the item in progress is removed.
    public func cancel(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        switch entry.state {
        case .queued:
            entry.state = .cancelled
            entry.finished = Date()
        case .running, .paused:
            entry.state = .cancelling
            entry.control.isPaused = false
            entry.task?.cancel()
        default:
            return
        }
        schedule()
        notify()
    }

    public func pause(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }), entry.state == .running else { return }
        entry.control.isPaused = true
        entry.state = .paused
        notify()
    }

    public func resume(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }), entry.state == .paused else { return }
        entry.control.isPaused = false
        entry.state = .running
        notify()
    }

    /// Starts a queued operation now, even if its disk is busy.
    public func startNow(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }), entry.state == .queued else { return }
        start(entry)
        notify()
    }

    /// Moves a queued operation up (negative) or down (positive) in the queue.
    public func move(_ id: UUID, by offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].state == .queued else { return }
        let queued = entries.indices.filter { entries[$0].state == .queued }
        guard let position = queued.firstIndex(of: index) else { return }
        let newPosition = max(0, min(queued.count - 1, position + offset))
        guard newPosition != position else { return }
        let entry = entries.remove(at: index)
        let targetIndex = entries.indices.filter { entries[$0].state == .queued }
        let insertAt = newPosition < targetIndex.count ? targetIndex[newPosition] : (targetIndex.last.map { $0 + 1 } ?? entries.count)
        entries.insert(entry, at: min(insertAt, entries.count))
        notify()
    }

    /// Removes finished operations from the list.
    public func clearFinished() {
        entries.removeAll { !$0.isActive }
        notify()
    }

    // MARK: - Reading

    public func snapshots() -> [Snapshot] {
        var position = 0
        return entries.map { entry in
            var queuePosition: Int?
            if entry.state == .queued {
                position += 1
                queuePosition = position
            }
            return Snapshot(
                id: entry.id, title: entry.operation.title, state: entry.state,
                progress: entry.control.progress, speed: entry.state == .running ? entry.control.speed : nil,
                started: entry.started, finished: entry.finished, queuePosition: queuePosition,
                canUndo: !entry.isActive && !entry.undone && !entry.undo.recorded.isEmpty && !entry.isUndoOperation,
                isUndo: entry.isUndoOperation, skippedEntries: entry.control.skippedEntries,
                destinationFolder: entry.operation.destinationFolder)
        }
    }

    /// Calls `observer` (on any thread) whenever an operation starts, finishes or changes state.
    public func observe(_ observer: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func stopObserving(_ id: UUID) {
        observers[id] = nil
    }

    /// Waits until no operation is queued or running. For tests.
    public func waitUntilIdle() async {
        while entries.contains(where: \.isActive) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Scheduling

    private func schedule() {
        var busyDisks = Set(entries.filter { $0.state == .running || $0.state == .paused || $0.state == .cancelling }.map(\.disk))
        for entry in entries where entry.state == .queued && !busyDisks.contains(entry.disk) {
            busyDisks.insert(entry.disk)
            start(entry)
        }
    }

    private func start(_ entry: Entry) {
        entry.state = .running
        entry.started = Date()
        let engine = engine
        let resolver = resolveConflict
        let operation = entry.operation
        let control = entry.control
        let undo = entry.undo
        let id = entry.id
        entry.task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: State
            do {
                try await engine.run(operation, control: control, undo: undo, resolveConflict: resolver)
                result = .done
            } catch is CancellationError {
                result = .cancelled
            } catch OperationError.stoppedByUser {
                result = .cancelled
            } catch {
                result = .failed(error.localizedDescription)
            }
            await self?.finish(id, result)
        }
    }

    private func finish(_ id: UUID, _ result: State) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entry.state = (entry.state == .cancelling && result == .done) ? .cancelled : result
        entry.finished = Date()
        entry.task = nil
        schedule()
        notify()
    }

    private func notify() {
        for observer in observers.values { observer() }
    }

    private func trimHistory() {
        let finished = entries.filter { !$0.isActive }
        if finished.count > historyLimit {
            let drop = Set(finished.prefix(finished.count - historyLimit).map(\.id))
            entries.removeAll { drop.contains($0.id) }
        }
    }

    // MARK: - Helpers

    /// The disk an operation works on, for running one at a time per disk.
    private static func disk(for operation: FileOperation) -> dev_t {
        let path = (operation.destinationFolder ?? operation.touchedItems.first)?.path ?? "/"
        return FileEngine.lstatInfo(path)?.st_dev ?? 0
    }

    /// Whether one path is the other or lies inside it.
    private static func overlaps(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
}

extension OperationCenter {
    /// Number of operations queued or running.
    public func activeCount() -> Int {
        entries.filter(\.isActive).count
    }
}

extension OperationCenter.State {
    var isActive: Bool {
        switch self {
        case .queued, .running, .paused, .cancelling: true
        default: false
        }
    }
}
