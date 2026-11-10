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
        /// Removes items for good, skipping the Trash. The engine asks first,
        /// once per disk, naming every item; nothing is removed on a no.
        case deletePermanently([URL])
        /// Adds a Finder tag to items, or with `applied` false takes it off.
        case setTag([URL], tag: String, applied: Bool)
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
            .deletePermanently(let items), .compress(let items, _), .setTag(let items, _, _):
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
        case .move(let items, _), .trash(let items), .deletePermanently(let items): items
        case .rename(let item, _): [item]
        case .ejectVolume(let item): [item]
        case .undo(let record): record.steps.flatMap(\.touchedItems)
        case .copy, .duplicate, .compress, .extract, .newFolder, .mountImage, .setTag: []
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
        case .deletePermanently(let items): "Deleting \(Self.describe(items)) permanently"
        case .setTag(let items, let tag, let applied):
            applied ? "Tagging \(Self.describe(items)) \(tag)" : "Removing the \(tag) tag from \(Self.describe(items))"
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
        case .trash, .deletePermanently, .move, .copy: true
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
    public let device: UInt64
    public let inode: UInt64
    public let kind: UInt32
    /// Nanoseconds since 1970.
    public let modified: Int64
    public let size: Int64
    /// A snapshot of descendants for a created directory; nil if it could not be read.
    public let directoryVersion: Data?

    public init(
        inode: UInt64, modified: Int64, size: Int64, device: UInt64 = 0, kind: UInt32 = 0, directoryVersion: Data? = nil
    ) {
        self.device = device
        self.kind = kind
        self.inode = inode
        self.modified = modified
        self.size = size
        self.directoryVersion = directoryVersion
    }
}

public enum UndoStep: Sendable, Hashable {
    /// Undo a create: move the item the operation made to the Trash.
    case trashCreated(URL, fileID: FileIdentity)
    /// Undo a rename or same-disk move: move it back.
    case moveBack(from: URL, to: URL, fileID: FileIdentity)
    /// Undo a trash: put the item back from the Trash.
    case putBack(trashed: URL, original: URL)

    var touchedItems: [URL] {
        switch self {
        case .trashCreated(let url, _): [url]
        case .moveBack(let from, let to, _): [from, to]
        case .putBack(let trashed, let original): [trashed, original]
        }
    }
}

/// Collects undo steps while an operation runs, so even a cancelled or failed
/// operation can undo the part it finished. It also hears about every change
/// the operation makes to a folder, undoable or not, for `onChange`.
public final class UndoRecorder: Sendable {
    private let steps = Mutex<[UndoStep]>([])
    private let onChange: (@Sendable (FolderItemsChanged) -> Void)?

    /// `onChange` hears each change as it is made, on the worker's thread.
    public init(onChange: (@Sendable (FolderItemsChanged) -> Void)? = nil) {
        self.onChange = onChange
    }

    /// Records a step and announces the change it reverses.
    func add(_ step: UndoStep) {
        steps.withLock { $0.append(step) }
        announce(FolderItemsChanged.changes(for: step))
    }

    /// Announces changes that have no undo step: undoing, deleting for good.
    func announce(_ changes: [FolderItemsChanged]) {
        guard let onChange else { return }
        changes.forEach(onChange)
    }

    public var recorded: [UndoStep] {
        steps.withLock { $0 }
    }

    /// Undo applies the newest steps first. Retire only steps it completed,
    /// so retrying a partial undo cannot repeat a successful step.
    func consumeLast(_ count: Int) {
        steps.withLock { $0.removeLast(min(count, $0.count)) }
    }
}

/// One top-level transfer result. A folder's counts include its descendants.
public struct TransferOutcome: Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        case completed
        case skipped(String)
        case failedAndSkipped(String)
        case failed(String)

        /// The skip reason or diagnostic; empty for a completed item.
        public var reason: String {
            switch self {
            case .completed: ""
            case .skipped(let message), .failedAndSkipped(let message), .failed(let message): message
            }
        }

        public var isSkipped: Bool {
            switch self {
            case .skipped, .failedAndSkipped: true
            default: false
            }
        }
    }
    public let item: URL
    public let items: Int
    public let bytes: Int64
    public let result: Result
}

/// Bounded per-operation report. Every outcome is counted, and a batch never
/// stops because of the report. Outcomes are listed in order until the list
/// reaches `maxOutcomes` or `maxTextBytes`; after that, a skipped or failed
/// outcome takes the place of the latest listed completed one, and whatever
/// is not listed is counted in `unlistedCount`.
public struct TransferReport: Sendable, Equatable {
    public static let maxOutcomes = 1_000
    public static let maxTextBytes = 512 * 1024
    static let reasonBudget = 4 * 1024
    public internal(set) var outcomes: [TransferOutcome] = []
    /// Outcomes counted but not listed, because the list was full.
    public internal(set) var unlistedCount = 0
    /// Every skipped item, listed or not.
    public internal(set) var skippedCount = 0
    public internal(set) var transferredBytes: Int64 = 0
    public internal(set) var notStarted = 0
    var textBytes = 0

    /// True when some outcome was not a plain completion.
    public var hasProblems: Bool {
        skippedCount > 0 || outcomes.contains { $0.result != .completed }
    }

    mutating func record(_ outcome: TransferOutcome, limit: Int) {
        if outcome.result.isSkipped { skippedCount += 1 }
        let cost = Self.cost(of: outcome)
        if outcomes.count < limit, cost <= Self.maxTextBytes - textBytes {
            outcomes.append(outcome)
            textBytes += cost
            return
        }
        // A full list keeps the problems visible: they displace completions.
        if outcome.result != .completed, let index = outcomes.lastIndex(where: { $0.result == .completed }) {
            let removed = outcomes.remove(at: index)
            textBytes -= Self.cost(of: removed)
            unlistedCount += 1
            if cost <= Self.maxTextBytes - textBytes {
                outcomes.append(outcome)
                textBytes += cost
                return
            }
        }
        unlistedCount += 1
    }

    private static func cost(of outcome: TransferOutcome) -> Int {
        outcome.item.path.utf8.count + outcome.result.reason.utf8.count
    }

    static func diagnostic(_ error: any Error) -> String {
        let message = error.localizedDescription
        guard message.utf8.count > reasonBudget else { return message }
        var result = ""
        for scalar in message.unicodeScalars {
            if result.utf8.count + scalar.utf8.count > reasonBudget - 32 { break }
            result.unicodeScalars.append(scalar)
        }
        return result + " [message shortened]"
    }
}

/// Pause and progress for one running operation, shared between the worker
/// and whoever displays it.
public final class OperationControl: Sendable {
    private let state = Mutex(State())
    private let reportOutcomeLimit: Int

    struct State {
        var paused = false
        var progress = OperationProgress()
        var samples: [(time: TimeInterval, bytes: Int64)] = []
        var skippedEntries: [String] = []
        var transferReport: TransferReport?
    }

    public init() { reportOutcomeLimit = TransferReport.maxOutcomes }

    // Lets a tiny fixture exercise the list limit without 1,001 files.
    init(reportOutcomeLimit: Int) {
        self.reportOutcomeLimit = min(max(0, reportOutcomeLimit), TransferReport.maxOutcomes)
    }

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

    public var transferReport: TransferReport? {
        state.withLock { $0.transferReport }
    }

    func beginTransferReport(notStarted: Int = 0) {
        state.withLock {
            var report = TransferReport()
            report.notStarted = notStarted
            $0.transferReport = report
        }
    }

    func setNotStarted(_ count: Int) {
        state.withLock { $0.transferReport?.notStarted = count }
    }

    func recordOutcome(_ outcome: TransferOutcome, transferredBytes: Int64 = 0) {
        state.withLock { state in
            guard var report = state.transferReport else { return }
            report.record(outcome, limit: reportOutcomeLimit)
            report.transferredBytes += transferredBytes
            state.transferReport = report
        }
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

    /// Remove an entire unprocessed top-level item from the measured plan.
    func removePending(bytes: Int64, items: Int) {
        update {
            $0.bytesTotal = max($0.bytesDone, $0.bytesTotal - bytes)
            $0.itemsTotal = max($0.itemsDone, $0.itemsTotal - items)
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
    /// Replace the existing file only when it was modified before the new
    /// one; otherwise skip. Folders are always kept, as with skip.
    case replaceIfOlder
    /// Keep both: the new item gets a numbered name ("photo 2.jpg").
    case keepBoth
    case skip
    case stop
}

/// The item itself, without following a symbolic link.
public enum ConflictItemKind: Sendable, Hashable {
    case file
    case directory
    case symbolicLink
    case other
    /// Metadata was unavailable, or the caller did not supply it.
    case unknown
}

public struct Conflict: Sendable, Equatable {
    public let incoming: URL
    public let existing: URL
    /// When each was last modified, for the question; read by the engine so
    /// the app doesn't touch the disk to ask.
    public var incomingModified: Date?
    public var existingModified: Date?
    public let incomingKind: ConflictItemKind
    public let existingKind: ConflictItemKind

    public init(
        incoming: URL, existing: URL, incomingModified: Date? = nil, existingModified: Date? = nil,
        incomingKind: ConflictItemKind = .unknown, existingKind: ConflictItemKind = .unknown
    ) {
        self.incoming = incoming
        self.existing = existing
        self.incomingModified = incomingModified
        self.existingModified = existingModified
        self.incomingKind = incomingKind
        self.existingKind = existingKind
    }
}

/// What to do when an item can't be copied or moved, such as after a read error.
public enum FailureChoice: Sendable, Equatable {
    /// Try the item again from the start.
    case retry
    /// Leave the item out and go on with the rest.
    case skip
    /// End the operation with the error.
    case stop
}

/// An item that couldn't be copied or moved. Nothing of it was left at the
/// destination, and an item it was to replace is back in place.
public struct ItemFailure: Sendable, Equatable {
    public let item: URL
    public let message: String

    public init(item: URL, message: String) {
        self.item = item
        self.message = message
    }
}

/// Answers a failure; `applyToAll` with skip skips every later failure too.
/// Retry and stop are never remembered.
public typealias FailureResolver = @Sendable (ItemFailure) async -> (choice: FailureChoice, applyToAll: Bool)

/// Answers a conflict; `applyToAll` reuses the answer for the same item-kind pair.
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
    case copiedSourceChanged(String)
    case copyFinalizationFailed(String, String)
    case notAnArchive(String)
    case archive(String)
    case undoNotPossible(String)
    /// Items an undo would trash were edited since, and the user wasn't asked.
    case changedSince([String])
    case mountFailed(String)
    case needsUnsandboxedBuild
    case notEnoughSpace(needed: Int64, available: Int64, volume: String)
    case incompatibleDestination(PreflightReport)
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
        case .copiedSourceChanged(let path):
            "“\((path as NSString).lastPathComponent)” was copied, but the source changed or could not be checked and was kept."
        case .copyFinalizationFailed(let name, let reason):
            "\(reason) The move of “\(name)” did not complete; the source was kept."
        case .notAnArchive(let path): "\((path as NSString).lastPathComponent) isn't an archive Scope can open."
        case .archive(let message): message
        case .undoNotPossible(let reason): "Can't undo: \(reason)"
        case .changedSince(let names):
            "\(names.map { "“\($0)”" }.joined(separator: ", ")) changed since, so nothing was undone."
        case .mountFailed(let message): message
        case .needsUnsandboxedBuild: "Mounting disk images doesn't work in a sandboxed build."
        case .notEnoughSpace(let needed, let available, let volume):
            "\(volume) doesn't have enough free space: this needs \(Self.bytes(needed)), "
                + "and \(Self.bytes(available)) is free. Nothing was copied."
        case .incompatibleDestination(let report): report.description
        case .fileTooLarge(let name, let volume):
            "“\(name)” is larger than 4 GB, which \(volume) can't store (its format is FAT32). Nothing was copied."
        case .nameNotAllowed(let name, let volume):
            "\(volume) can't store the name “\(name)”: FAT and exFAT disks don't allow \\ / : * ? \" < > |, "
                + "or a name ending in a space or a dot. Nothing was copied."
        }
    }
}
