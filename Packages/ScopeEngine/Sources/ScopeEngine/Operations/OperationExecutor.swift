import CryptoKit
import Foundation

/// Runs one file operation. Every path passes the path guard; nothing is ever
/// overwritten or deleted outright: a replaced item goes to the Trash only once its
/// replacement is complete, and a move across disks trashes the original only
/// after the copy is verified.
extension FileEngine {
    public func run(
        _ operation: FileOperation,
        control: OperationControl,
        undo: UndoRecorder,
        resolveConflict: @escaping ConflictResolver,
        confirmPermanentDeletion: @escaping PermanentDeletionConfirmer = { _ in false },
        resolveFailure: @escaping FailureResolver = { _ in (.stop, false) }
    ) async throws {
        try await onIOThreads {
            var conflicts = ConflictPolicy(resolver: resolveConflict)
            var failures = FailurePolicy(resolver: resolveFailure)
            switch operation.kind {
            case .copy(let items, let folder):
                try await transfer(
                    items, into: folder, moving: false, control: control, undo: undo, conflicts: &conflicts,
                    failures: &failures)
            case .move(let items, let folder):
                try await transfer(
                    items, into: folder, moving: true, control: control, undo: undo, conflicts: &conflicts,
                    failures: &failures)
            case .duplicate(let items):
                try await duplicate(items, control: control, undo: undo)
            case .rename(let item, let name):
                let renamed = try await rename(item, to: name)
                undo.add(.moveBack(from: renamed, to: try pathGuard.checkLocation(item)))
            case .newFolder(let folder, let name):
                let target = try uniqueName(name, in: try pathGuard.checkWriteLocation(folder), style: .numbered)
                try await createFolder(at: target)
                undo.add(.trashCreated(target, fileID: Self.fileID(target)))
            case .trash(let items):
                try await trash(items, control: control, undo: undo, confirm: confirmPermanentDeletion)
            case .compress(let items, let format):
                try await compress(items, format: format, control: control, undo: undo)
            case .extract(let archive):
                try await extract(archive, control: control, undo: undo)
            case .mountImage(let image, let readOnly, let mountPoint):
                try await mountImage(image, readOnly: readOnly, mountPoint: mountPoint)
            case .ejectVolume(let volume):
                try await Volumes.eject(volume, pathGuard: pathGuard)
            case .undo(let record):
                try await applyUndo(record, control: control, undo: undo)
            }
        }
    }

    // MARK: - Copy and move

    private func transfer(
        _ items: [URL], into folder: URL, moving: Bool, control: OperationControl,
        undo: UndoRecorder, conflicts: inout ConflictPolicy, failures: inout FailurePolicy
    ) async throws {
        let destination = try pathGuard.checkWriteLocation(folder)
        let sources = try items.map { try pathGuard.checkLocation($0) }
        let totals = try measure(sources)
        control.update {
            $0.bytesTotal = totals.bytes
            $0.itemsTotal = totals.items
        }
        try preflight(sources, into: destination, moving: moving)

        for source in sources {
            try Task.checkCancellation()
            try control.waitWhilePaused()
            let sameFolder = source.deletingLastPathComponent().path == destination.path
            if moving && sameFolder { continue }
            var target = destination.appendingPathComponent(source.lastPathComponent)
            var replacing = false
            if Self.lstatInfo(target.path) != nil {
                if sameFolder {
                    // Pasting a copy into its own folder makes "name copy", like Finder.
                    target = try uniqueName(source.lastPathComponent, in: destination, style: .copy)
                } else {
                    let conflict = Conflict(
                        incoming: source, existing: target, incomingModified: Self.modified(source),
                        existingModified: Self.modified(target))
                    var choice = try await conflicts.resolve(conflict)
                    if choice == .replaceIfOlder {
                        choice = Self.isOlderFile(target, than: source) ? .replace : .skip
                    }
                    switch choice {
                    case .skip, .replaceIfOlder:
                        control.update { $0.itemsDone += 1 }
                        continue
                    case .keepBoth:
                        target = try uniqueName(source.lastPathComponent, in: destination, style: .numbered)
                    case .replace:
                        guard !Self.isInside(source.path, target.path) else {
                            throw FileEngineError.cannotCopyIntoItself(source.path)
                        }
                        // The existing item stays until its replacement is ready.
                        replacing = true
                    case .stop:
                        throw OperationError.stoppedByUser
                    }
                }
            }

            let sameDisk = Self.lstatInfo(source.path)?.st_dev == Self.lstatInfo(destination.path)?.st_dev
            if moving && sameDisk {
                // A rename is instant, so the existing item is trashed just
                // before it, and put back if the rename fails.
                var trashed: URL?
                var moved = false
                while !moved {
                    if replacing, Self.lstatInfo(target.path) != nil { trashed = try trashItemNow(target) }
                    do {
                        try await moveItem(at: source, to: target)
                        moved = true
                    } catch {
                        if let trashed { restoreReplaced(trashed, to: target, undo: undo) }
                        trashed = nil
                        guard try await failures.retry(source, after: error) else { break }
                    }
                }
                guard moved else {
                    control.update { $0.itemsDone += 1 }
                    continue
                }
                if let trashed { undo.add(.putBack(trashed: trashed, original: target)) }
                undo.add(.moveBack(from: target, to: source))
                let size = (try? measure([target]))?.bytes ?? 0
                control.update {
                    $0.bytesDone += size
                    $0.itemsDone += 1
                    $0.currentItem = source.lastPathComponent
                }
                continue
            }

            // The copy is written under a partial name. Only when it is complete
            // (and, for a move, verified) does a replaced item go to the Trash,
            // right before the copy is renamed into its place.
            let replaced = ReplacedItem()
            let existing = replacing ? target : nil
            let placeCopy: (URL, URL) throws -> Void = { original, partial in
                if moving {
                    control.update { $0.currentItem = "Verifying \(original.lastPathComponent)" }
                    try self.verifyCopy(original, partial, control: control)
                }
                if let existing, Self.lstatInfo(existing.path) != nil {
                    replaced.trashed = try self.trashItemNow(existing)
                }
            }
            // A failed attempt leaves nothing behind and puts a replaced item
            // back, so the item can be tried again from the start.
            let before = control.progress
            var copied = false
            while !copied {
                do {
                    try copyTracked(
                        source, to: target, control: control, replacingExisting: replacing, beforePlacing: placeCopy)
                    copied = true
                } catch {
                    if let trashed = replaced.trashed { restoreReplaced(trashed, to: target, undo: undo) }
                    replaced.trashed = nil
                    control.update {
                        $0.bytesDone = before.bytesDone
                        $0.itemsDone = before.itemsDone
                    }
                    guard try await failures.retry(source, after: error) else { break }
                }
            }
            guard copied else {
                control.update { $0.itemsDone += 1 }
                continue
            }
            if let trashed = replaced.trashed { undo.add(.putBack(trashed: trashed, original: target)) }
            undo.add(.trashCreated(target, fileID: Self.fileID(target)))
            if moving {
                // From here the move finishes even if cancelled: the copy is in
                // place and verified, so the original goes to the Trash.
                let trashed = try trashItemNow(source)
                if let trashed { undo.add(.putBack(trashed: trashed, original: source)) }
            }
        }
    }

    /// Puts back an item that was trashed to make room for a replacement that
    /// then failed. If that isn't possible, the operation's undo can still do it.
    private func restoreReplaced(_ trashed: URL, to original: URL, undo: UndoRecorder) {
        do {
            try placeBack(trashed, at: original)
        } catch {
            undo.add(.putBack(trashed: trashed, original: original))
        }
    }

    /// A synchronous same-disk rename back from the Trash, for cleanup paths
    /// that must not be interrupted by cancellation.
    private func placeBack(_ trashed: URL, at original: URL) throws {
        let from = try pathGuard.checkPutBack(trashed)
        let to = try pathGuard.checkWriteLocation(original)
        guard Self.renameExclusively(from.path, to: to.path) else {
            throw FileEngineError.posix("Put back", from.path)
        }
    }

    /// Copies one item and adds its progress to the operation's totals.
    private func copyTracked(
        _ source: URL, to target: URL, control: OperationControl, replacingExisting: Bool = false,
        beforePlacing: ((URL, URL) throws -> Void)? = nil
    ) throws {
        let base = control.progress
        try copyItem(
            at: source, to: target, control: control,
            progress: { progress in
                control.update {
                    $0.bytesDone = base.bytesDone + progress.bytesDone
                    $0.itemsDone = base.itemsDone + progress.itemsDone
                    $0.currentItem =
                        progress.currentItem.isEmpty
                        ? source.lastPathComponent
                        : source.lastPathComponent + "/" + progress.currentItem
                }
            }, replacingExisting: replacingExisting, beforePlacing: beforePlacing)
    }

    private func duplicate(_ items: [URL], control: OperationControl, undo: UndoRecorder) async throws {
        let sources = try items.map { try pathGuard.checkLocation($0) }
        let totals = try measure(sources)
        control.update {
            $0.bytesTotal = totals.bytes
            $0.itemsTotal = totals.items
        }
        for source in sources {
            try Task.checkCancellation()
            let target = try uniqueName(source.lastPathComponent, in: source.deletingLastPathComponent(), style: .copy)
            try copyTracked(source, to: target, control: control)
            undo.add(.trashCreated(target, fileID: Self.fileID(target)))
        }
    }

    /// Trashes without a cancellation check, for the last step of a move and
    /// for the item a finished replacement takes the place of.
    private func trashItemNow(_ url: URL) throws -> URL? {
        try moveToTrash(try pathGuard.checkModifiable(url))
    }

    // MARK: - Verification

    /// Confirms a copy matches its original: same structure, sizes, link
    /// targets and SHA-256 of every file's contents.
    func verifyCopy(_ original: URL, _ copy: URL, control: OperationControl?) throws {
        try verifyCopy(
            CopyLocation(checked: pathGuard.checkLocation(original)),
            CopyLocation(checked: pathGuard.checkWriteLocation(copy)), control: control)
    }

    private func verifyCopy(_ original: CopyLocation, _ copy: CopyLocation, control: OperationControl?) throws {
        try Task.checkCancellation()
        let a = try original.info()
        let b = try copy.info()
        guard a.st_mode & S_IFMT == b.st_mode & S_IFMT else {
            throw OperationError.verificationFailed(original.path)
        }
        switch a.st_mode & S_IFMT {
        case S_IFDIR:
            let source = try original.open(O_RDONLY | O_DIRECTORY, matching: a)
            let destination = try copy.open(O_RDONLY | O_DIRECTORY, matching: b)
            let left = try CopyLocation.names(in: source, path: original.path).sorted()
            let right = try CopyLocation.names(in: destination, path: copy.path).sorted()
            guard left == right else { throw OperationError.verificationFailed(original.path) }
            for name in left {
                try verifyCopy(original.child(name, in: source), copy.child(name, in: destination), control: control)
            }
        case S_IFLNK:
            guard try original.linkTarget() == copy.linkTarget() else {
                throw OperationError.verificationFailed(original.path)
            }
        case S_IFREG:
            let source = try original.open(O_RDONLY, matching: a)
            let destination = try copy.open(O_RDONLY, matching: b)
            guard a.st_size == b.st_size,
                try Self.sha256(source, control: control) == Self.sha256(destination, control: control)
            else { throw OperationError.verificationFailed(original.path) }
        default: break
        }
    }

    private static func sha256(_ descriptor: CopyDescriptor, control: OperationControl?) throws -> SHA256.Digest {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var offset: off_t = 0
        while true {
            try Task.checkCancellation()
            try control?.waitWhilePaused()
            let count = pread(descriptor.raw, &buffer, buffer.count, offset)
            if count < 0 {
                if errno == EINTR { continue }
                throw FileEngineError.posix("Verify open file", "descriptor")
            }
            guard count > 0 else { return hasher.finalize() }
            hasher.update(data: Data(buffer.prefix(count)))
            offset += off_t(count)
        }
    }

    // MARK: - Undo

    private func applyUndo(_ record: UndoRecord, control: OperationControl, undo: UndoRecorder) async throws {
        // Checked for every step before any is applied, so a no leaves the
        // whole operation as it is.
        let changed = Self.changedSinceMade(record)
        if !changed.isEmpty, !record.includesChangedItems {
            throw OperationError.changedSince(changed.map(\.lastPathComponent))
        }
        control.update { $0.itemsTotal = record.steps.count }
        for step in record.steps.reversed() {
            try Task.checkCancellation()
            switch step {
            case .trashCreated(let url, let fileID):
                guard Self.lstatInfo(url.path) != nil else { break }
                guard Self.fileID(url).inode == fileID.inode else {
                    throw OperationError.undoNotPossible("“\(url.lastPathComponent)” has been replaced since.")
                }
                _ = try await trashItem(at: url)
            case .moveBack(let from, let to):
                guard Self.lstatInfo(from.path) != nil else {
                    throw OperationError.undoNotPossible("“\(from.lastPathComponent)” isn't there anymore.")
                }
                if from.lastPathComponent != to.lastPathComponent,
                    from.deletingLastPathComponent() == to.deletingLastPathComponent()
                {
                    try await rename(from, to: to.lastPathComponent)
                } else {
                    try await moveItem(at: from, to: to)
                }
            case .putBack(let trashed, let original):
                guard Self.lstatInfo(trashed.path) != nil else {
                    throw OperationError.undoNotPossible("“\(trashed.lastPathComponent)” is no longer in the Trash.")
                }
                try await moveItem(at: trashed, to: original, puttingBack: true)
            }
            // Undoing a step reverses the change it recorded.
            undo.announce(FolderItemsChanged.changes(for: step).map(\.reversed))
            control.update { $0.itemsDone += 1 }
        }
    }

    // MARK: - Dates

    /// When an item was last modified, without following a link.
    static func modified(_ url: URL) -> Date? {
        guard let info = lstatInfo(url.path) else { return nil }
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }

    /// Whether `existing` and `incoming` are both files (not folders) and
    /// `existing` was modified first, for "Replace if older".
    static func isOlderFile(_ existing: URL, than incoming: URL) -> Bool {
        guard let old = lstatInfo(existing.path), let new = lstatInfo(incoming.path),
            old.st_mode & S_IFMT != S_IFDIR, new.st_mode & S_IFMT != S_IFDIR
        else { return false }
        let oldTime = (old.st_mtimespec.tv_sec, old.st_mtimespec.tv_nsec)
        let newTime = (new.st_mtimespec.tv_sec, new.st_mtimespec.tv_nsec)
        return oldTime < newTime
    }

    // MARK: - Names

    enum NameStyle { case numbered, copy }

    /// A free name in `folder`: "photo 2.jpg" (numbered) or "photo copy.jpg",
    /// "photo copy 2.jpg" (copy), as Finder names them.
    func uniqueName(_ name: String, in folder: URL, style: NameStyle) throws -> URL {
        let ns = name as NSString
        let isFolderLike = ns.pathExtension.isEmpty
        let base = isFolderLike ? name : ns.deletingPathExtension
        let suffix = isFolderLike ? "" : "." + ns.pathExtension
        var candidates: [String] = []
        switch style {
        case .numbered:
            candidates.append(name)
            candidates += (2...10_000).lazy.map { "\(base) \($0)\(suffix)" }.prefix(9_999)
        case .copy:
            candidates.append("\(base) copy\(suffix)")
            candidates += (2...10_000).lazy.map { "\(base) copy \($0)\(suffix)" }.prefix(9_999)
        }
        for candidate in candidates {
            let url = folder.appendingPathComponent(candidate)
            if Self.lstatInfo(url.path) == nil { return try pathGuard.checkWriteLocation(url) }
        }
        throw FileEngineError.destinationExists(folder.appendingPathComponent(name).path)
    }

    /// The item's identity now; all zero when it is missing. A folder's
    /// version isn't kept: its time changes whenever an item is added or
    /// removed, even by a later operation that undo reverses first.
    static func fileID(_ url: URL) -> FileIdentity {
        guard let info = lstatInfo(url.path) else { return FileIdentity(inode: 0, modified: 0, size: 0) }
        if info.st_mode & S_IFMT == S_IFDIR { return FileIdentity(inode: UInt64(info.st_ino), modified: 0, size: 0) }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return FileIdentity(inode: UInt64(info.st_ino), modified: modified, size: Int64(info.st_size))
    }

    /// Files an undo would move to the Trash that were edited after the
    /// operation made them: same file, other modification time or size. A
    /// replaced or missing item isn't listed; undo handles those itself.
    static func changedSinceMade(_ record: UndoRecord) -> [URL] {
        record.steps.compactMap { step in
            guard case .trashCreated(let url, let made) = step else { return nil }
            let now = fileID(url)
            return now.inode != 0 && now.inode == made.inode && now != made ? url : nil
        }
    }

    /// Items an undo of `record` would trash that were edited since, for
    /// asking before the undo starts.
    public func changedSinceMade(_ record: UndoRecord) async -> [URL] {
        await onIOThreads { Self.changedSinceMade(record) }
    }
}

/// Remembers "apply to all" answers within one operation.
struct ConflictPolicy {
    let resolver: ConflictResolver
    var remembered: ConflictChoice?

    init(resolver: @escaping ConflictResolver) {
        self.resolver = resolver
    }

    mutating func resolve(_ conflict: Conflict) async throws -> ConflictChoice {
        if let remembered { return remembered }
        try Task.checkCancellation()
        let (choice, applyToAll) = await resolver(conflict)
        // A cancel while the question was open wins over the answer.
        try Task.checkCancellation()
        if applyToAll { remembered = choice }
        return choice
    }
}

/// Asks what to do when an item fails, and remembers "skip all".
struct FailurePolicy {
    let resolver: FailureResolver
    var skipAll = false

    init(resolver: @escaping FailureResolver) {
        self.resolver = resolver
    }

    /// Whether to try `item` again after `error`: false to skip it. Throws
    /// the error to stop. Errors another try can't fix are never asked about.
    mutating func retry(_ item: URL, after error: any Error) async throws -> Bool {
        guard Self.isRetryable(error) else { throw error }
        if skipAll { return false }
        try Task.checkCancellation()
        let (choice, applyToAll) = await resolver(ItemFailure(item: item, message: error.localizedDescription))
        // A cancel while the question was open wins over the answer.
        try Task.checkCancellation()
        switch choice {
        case .retry: return true
        case .skip:
            if applyToAll { skipAll = true }
            return false
        case .stop: throw error
        }
    }

    /// Read and write errors and failed verifications can pass on another
    /// try; cancelling, the path guard, and refusals by design can't.
    static func isRetryable(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError, is PathGuardViolation: false
        case OperationError.stoppedByUser: false
        case FileEngineError.cannotCopyIntoItself, FileEngineError.destinationExists: false
        case FileEngineError.crossVolumeMoveNotSupported: false
        default: true
        }
    }
}

/// The item a replacement sent to the Trash, filled in by the copy's last step.
private final class ReplacedItem {
    var trashed: URL?
}
