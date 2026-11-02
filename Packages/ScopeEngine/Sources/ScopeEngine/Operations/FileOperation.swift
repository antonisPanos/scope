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
        case .copy(let items, _), .move(let items, _), .duplicate(let items), .trash(let items),
            .compress(let items, _):
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
    /// Items this operation renames, moves away or trashes. Nothing else may
    /// use them (or anything inside them) while it runs.
    var changedItems: [URL] {
        switch kind {
        case .move(let items, _), .trash(let items): items
        case .rename(let item, _): [item]
        case .ejectVolume(let item): [item]
        case .undo(let record): record.steps.flatMap(\.touchedItems)
        case .copy, .duplicate, .compress, .extract, .newFolder, .mountImage: []
        }
    }

    /// Everything the operation reads or writes into: its items and its
    /// destination folder. Two operations conflict when one changes an item
    /// that is, contains or lies inside one of the other's.
    var usedItems: [URL] {
        touchedItems + [destinationFolder].compactMap { $0 }
    }

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
    /// Whether the user agreed to undo even though items the operation made
    /// were changed since. Without it, such an undo changes nothing.
    public var includesChangedItems: Bool

    public init(title: String, steps: [UndoStep] = [], includesChangedItems: Bool = false) {
        self.title = title
        self.steps = steps
        self.includesChangedItems = includesChangedItems
    }
}

/// An item as an operation left it: which file it is, and which version. A
/// different inode means it was replaced; the same inode with another
/// modification time or size means it was edited in place.
public struct FileIdentity: Sendable, Hashable {
    public let inode: UInt64
    /// Nanoseconds since 1970.
    public let modified: Int64
    public let size: Int64

    public init(inode: UInt64, modified: Int64, size: Int64) {
        self.inode = inode
        self.modified = modified
        self.size = size
    }
}

public enum UndoStep: Sendable, Hashable {
    /// Undo a create: move the item the operation made to the Trash.
    case trashCreated(URL, fileID: FileIdentity)
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
            guard let first = state.samples.first, let last = state.samples.last, last.time > first.time + 0.3 else {
                return nil
            }
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

    /// Blocks the worker while paused. Cancelling ends the wait at once. The
    /// worker is one of the engine's I/O threads, so a paused job never holds
    /// a thread of the concurrency pool.
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
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    case itemsBusy([String])
    case stoppedByUser
    /// The user said no to deleting for good on a disk with no Trash.
    case noTrash(String)
    /// A folder being deleted for good has another disk mounted inside.
    case diskInside(String)
    case verificationFailed(String)
    case notAnArchive(String)
    case archive(String)
    case undoNotPossible(String)
    /// Items an undo would trash were edited since, and the user wasn't asked.
    case changedSince([String])
    case mountFailed(String)
    case needsUnsandboxedBuild
    case notEnoughSpace(needed: Int64, available: Int64, volume: String)
    case fileTooLarge(String, volume: String)
    case nameNotAllowed(String, volume: String)

    public var errorDescription: String? {
        switch self {
        case .itemsBusy(let names):
            "\(names.joined(separator: ", ")) \(names.count == 1 ? "is" : "are") in use by another operation."
        case .stoppedByUser: "Stopped."
        case .noTrash(let volume): "“\(volume)” has no Trash, so the items on it were kept."
        case .diskInside(let path): "\(path) has another disk mounted inside it, so it wasn't deleted."
        case .verificationFailed(let path): "The copy of \(path) didn't match the original, so the original was kept."
        case .notAnArchive(let path): "\((path as NSString).lastPathComponent) isn't an archive Scope can open."
        case .archive(let message): message
        case .undoNotPossible(let reason): "Can't undo: \(reason)"
        case .changedSince(let names):
            "\(names.map { "“\($0)”" }.joined(separator: ", ")) changed since, so nothing was undone."
        case .mountFailed(let message): message
        case .needsUnsandboxedBuild: "Mounting disk images needs the “Scope Dev (No Sandbox)” build."
        case .notEnoughSpace(let needed, let available, let volume):
            "\(volume) doesn't have enough free space: this needs \(Self.bytes(needed)), "
                + "and \(Self.bytes(available)) is free. Nothing was copied."
        case .fileTooLarge(let name, let volume):
            "“\(name)” is larger than 4 GB, which \(volume) can't store (its format is FAT32). Nothing was copied."
        case .nameNotAllowed(let name, let volume):
            "\(volume) can't store the name “\(name)”: FAT and exFAT disks don't allow \\ / : * ? \" < > |, "
                + "or a name ending in a space or a dot. Nothing was copied."
        }
    }
}
