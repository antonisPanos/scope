import Foundation
import Synchronization

/// A file operation as a value: what it does, to what, and where. The engine
/// runs it; the operation center queues, pauses and cancels it.
public struct FileOperation: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Copies items into a folder.
        case copy([URL], into: URL)
        /// Moves items into a folder: an instant rename on the same disk; copy,
        /// verify and then Trash the original across disks.
        case move([URL], into: URL)
        /// Copies items next to themselves as "name copy".
        case duplicate([URL])
        case rename(URL, to: String)
        case newFolder(in: URL, name: String)
        case trash([URL])
        /// Compresses items into one archive next to the first item.
        case compress([URL], format: ArchiveFormat)
        /// Extracts an archive next to itself.
        case extract(URL)
        case mountImage(URL, readOnly: Bool, mountPoint: URL?)
        case ejectVolume(URL)
        /// Reverses an earlier operation.
        case undo(UndoRecord)
    }

    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    /// The items the operation reads or changes, for locking and conflict checks.
    public var touchedItems: [URL] {
        switch kind {
        case .copy(let items, _), .move(let items, _), .duplicate(let items), .trash(let items), .compress(let items, _):
            items
        case .rename(let item, _), .extract(let item), .mountImage(let item, _, _), .ejectVolume(let item):
            [item]
        case .newFolder(let folder, _):
            [folder]
        case .undo(let record):
            record.steps.flatMap(\.touchedItems)
        }
    }

    /// The folder new items appear in, when there is one.
    public var destinationFolder: URL? {
        switch kind {
        case .copy(_, let folder), .move(_, let folder): folder
        case .newFolder(let folder, _): folder
        case .duplicate(let items), .compress(let items, _): items.first?.deletingLastPathComponent()
        case .extract(let item): item.deletingLastPathComponent()
        default: nil
        }
    }

    /// A short description for the activity panel: "Copying 3 items to names".
    public var title: String {
        switch kind {
        case .copy(let items, let folder): "Copying \(Self.describe(items)) to \(folder.lastPathComponent)"
        case .move(let items, let folder): "Moving \(Self.describe(items)) to \(folder.lastPathComponent)"
        case .duplicate(let items): "Duplicating \(Self.describe(items))"
        case .rename(let item, let name): "Renaming “\(item.lastPathComponent)” to “\(name)”"
        case .newFolder(_, let name): "Creating “\(name)”"
        case .trash(let items): "Moving \(Self.describe(items)) to the Trash"
        case .compress(let items, let format): "Compressing \(Self.describe(items)) as \(format.fileExtension)"
        case .extract(let item): "Extracting “\(item.lastPathComponent)”"
        case .mountImage(let item, _, _): "Mounting “\(item.lastPathComponent)”"
        case .ejectVolume(let item): "Ejecting “\(item.lastPathComponent)”"
        case .undo(let record): "Undoing: \(record.title)"
        }
    }

    /// Whether the operation is a destructive one that key auto-repeat must not trigger.
    public var isDestructive: Bool {
        switch kind {
        case .trash, .move, .copy: true
        default: false
        }
    }

    static func describe(_ items: [URL]) -> String {
        items.count == 1 ? "“\(items[0].lastPathComponent)”" : "\(items.count) items"
    }
}

public enum ArchiveFormat: String, Sendable, Hashable, CaseIterable, Codable {
    case zip, tarGz, sevenZip

    public var fileExtension: String {
        switch self {
        case .zip: "zip"
        case .tarGz: "tar.gz"
        case .sevenZip: "7z"
        }
    }
}

/// How to reverse a finished (or partly finished) operation: steps applied
/// in reverse order. Each step checks the item is still what the operation
/// left behind, so undo never touches something that changed since.
public struct UndoRecord: Sendable, Hashable {
    public var title: String
    public var steps: [UndoStep]

    public init(title: String, steps: [UndoStep] = []) {
        self.title = title
        self.steps = steps
    }
}

public enum UndoStep: Sendable, Hashable {
    /// Undo a create: move the item the operation made to the Trash.
    case trashCreated(URL, fileID: UInt64)
    /// Undo a rename or same-disk move: move it back.
    case moveBack(from: URL, to: URL)
    /// Undo a trash: put the item back from the Trash.
    case putBack(trashed: URL, original: URL)

    var touchedItems: [URL] {
        switch self {
        case .trashCreated(let url, _): [url]
        case .moveBack(let from, let to): [from, to]
        case .putBack(let trashed, let original): [trashed, original]
        }
    }
}

/// Collects undo steps while an operation runs, so even a cancelled or failed
/// operation can undo the part it finished.
public final class UndoRecorder: Sendable {
    private let steps = Mutex<[UndoStep]>([])

    public init() {}

    func add(_ step: UndoStep) {
        steps.withLock { $0.append(step) }
    }

    public var recorded: [UndoStep] {
        steps.withLock { $0 }
    }
}

/// Pause and progress for one running operation, shared between the worker
/// and whoever displays it.
public final class OperationControl: Sendable {
    private let state = Mutex(State())

    struct State {
        var paused = false
        var progress = OperationProgress()
        var samples: [(time: TimeInterval, bytes: Int64)] = []
        var skippedEntries: [String] = []
    }

    public init() {}

    public var isPaused: Bool {
        get { state.withLock { $0.paused } }
        set { state.withLock { $0.paused = newValue } }
    }

    public var progress: OperationProgress {
        state.withLock { $0.progress }
    }

    /// Bytes per second over the last few seconds.
    public var speed: Double? {
        state.withLock { state in
            guard let first = state.samples.first, let last = state.samples.last, last.time > first.time + 0.3 else { return nil }
            return Double(last.bytes - first.bytes) / (last.time - first.time)
        }
    }

    /// Archive entries left out because they were unsafe (../ paths, links out).
    public var skippedEntries: [String] {
        state.withLock { $0.skippedEntries }
    }

    func update(_ change: (inout OperationProgress) -> Void) {
        state.withLock { state in
            change(&state.progress)
            let now = ProcessInfo.processInfo.systemUptime
            if state.samples.last.map({ now - $0.time > 0.1 }) ?? true {
                state.samples.append((now, state.progress.bytesDone))
                state.samples.removeAll { now - $0.time > 3 }
            }
        }
    }

    func skipEntry(_ name: String) {
        state.withLock { $0.skippedEntries.append(name) }
    }

    /// Blocks the worker while paused. Cancelling ends the wait at once.
    func waitWhilePaused() throws {
        while isPaused {
            try Task.checkCancellation()
            usleep(50_000)
        }
    }
}

public struct OperationProgress: Sendable, Equatable {
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64 = 0
    public var itemsDone = 0
    public var itemsTotal = 0
    public var currentItem = ""

    public var fraction: Double? {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        if itemsTotal > 0 { return min(1, Double(itemsDone) / Double(itemsTotal)) }
        return nil
    }
}

/// What to do when an item with the same name already exists at the destination.
public enum ConflictChoice: Sendable, Equatable {
    /// Move the existing item to the Trash, then put the new one in its place.
    case replace
    /// Keep both: the new item gets a numbered name ("photo 2.jpg").
    case keepBoth
    case skip
    case stop
}

public struct Conflict: Sendable, Equatable {
    public let incoming: URL
    public let existing: URL
}

/// Answers a conflict; `applyToAll` reuses the answer for the rest of the operation.
public typealias ConflictResolver = @Sendable (Conflict) async -> (choice: ConflictChoice, applyToAll: Bool)

public enum OperationError: Error, Equatable, LocalizedError {
    case itemsBusy([String])
    case stoppedByUser
    case verificationFailed(String)
    case notAnArchive(String)
    case archive(String)
    case undoNotPossible(String)
    case mountFailed(String)
    case needsUnsandboxedBuild

    public var errorDescription: String? {
        switch self {
        case .itemsBusy(let names): "\(names.joined(separator: ", ")) \(names.count == 1 ? "is" : "are") in use by another operation."
        case .stoppedByUser: "Stopped."
        case .verificationFailed(let path): "The copy of \(path) didn't match the original, so the original was kept."
        case .notAnArchive(let path): "\((path as NSString).lastPathComponent) isn't an archive Pandora can open."
        case .archive(let message): message
        case .undoNotPossible(let reason): "Can't undo: \(reason)"
        case .mountFailed(let message): message
        case .needsUnsandboxedBuild: "Mounting disk images needs the “Pandora Dev (No Sandbox)” build."
        }
    }
}
