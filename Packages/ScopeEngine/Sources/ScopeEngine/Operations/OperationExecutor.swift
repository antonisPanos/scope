import CryptoKit
import Foundation

/// Runs one file operation. Every path passes the path guard; nothing is ever
/// overwritten or deleted: a replaced item goes to the Trash only once its
/// replacement is complete, and a move across disks trashes the original only
/// after the copy is verified.
extension FileEngine {
    public func run(
        _ operation: FileOperation,
        control: OperationControl,
        undo: UndoRecorder,
        resolveConflict: @escaping ConflictResolver
    ) async throws {
        var conflicts = ConflictPolicy(resolver: resolveConflict)
        switch operation.kind {
        case .copy(let items, let folder):
            try await transfer(items, into: folder, moving: false, control: control, undo: undo, conflicts: &conflicts)
        case .move(let items, let folder):
            try await transfer(items, into: folder, moving: true, control: control, undo: undo, conflicts: &conflicts)
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
            try await trash(items, control: control, undo: undo)
        case .compress(let items, let format):
            try await compress(items, format: format, control: control, undo: undo)
        case .extract(let archive):
            try await extract(archive, control: control, undo: undo)
        case .mountImage(let image, let readOnly, let mountPoint):
            try await mountImage(image, readOnly: readOnly, mountPoint: mountPoint)
        case .ejectVolume(let volume):
            try await Volumes.eject(volume, pathGuard: pathGuard)
        case .undo(let record):
            try await applyUndo(record, control: control)
        }
    }

    // MARK: - Copy and move

    private func transfer(
        _ items: [URL], into folder: URL, moving: Bool, control: OperationControl,
        undo: UndoRecorder, conflicts: inout ConflictPolicy
    ) async throws {
        let destination = try pathGuard.checkWriteLocation(folder)
        let sources = try items.map { try pathGuard.checkLocation($0) }
        let totals = try measure(sources)
        control.update {
            $0.bytesTotal = totals.bytes
            $0.itemsTotal = totals.items
        }

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
                    switch try await conflicts.resolve(Conflict(incoming: source, existing: target)) {
                    case .skip:
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
                if replacing { trashed = try trashItemNow(target) }
                do {
                    try await moveItem(at: source, to: target)
                } catch {
                    if let trashed { restoreReplaced(trashed, to: target, undo: undo) }
                    throw error
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
            do {
                try copyTracked(
                    source, to: target, control: control, replacingExisting: replacing, beforePlacing: placeCopy)
            } catch {
                if let trashed = replaced.trashed { restoreReplaced(trashed, to: target, undo: undo) }
                throw error
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
        let from = try pathGuard.checkWriteLocation(trashed)
        let to = try pathGuard.checkWriteLocation(original)
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
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

    private func trash(_ items: [URL], control: OperationControl, undo: UndoRecorder) async throws {
        control.update { $0.itemsTotal = items.count }
        for item in items {
            try Task.checkCancellation()
            let original = try pathGuard.checkWriteLocation(item)
            control.update { $0.currentItem = original.lastPathComponent }
            if let trashed = try await trashItem(at: original) {
                undo.add(.putBack(trashed: trashed, original: original))
            }
            control.update { $0.itemsDone += 1 }
        }
    }

    /// Trashes without a cancellation check, for the last step of a move and
    /// for the item a finished replacement takes the place of.
    private func trashItemNow(_ url: URL) throws -> URL? {
        let target = try pathGuard.checkWriteLocation(url)
        var resulting: NSURL?
        try FileManager.default.trashItem(at: target, resultingItemURL: &resulting)
        return resulting as URL?
    }

    // MARK: - Verification

    /// Confirms a copy matches its original: same structure, sizes, link
    /// targets and SHA-256 of every file's contents.
    func verifyCopy(_ original: URL, _ copy: URL, control: OperationControl?) throws {
        try Task.checkCancellation()
        guard let a = Self.lstatInfo(original.path), let b = Self.lstatInfo(copy.path),
            a.st_mode & S_IFMT == b.st_mode & S_IFMT
        else {
            throw OperationError.verificationFailed(original.path)
        }
        switch a.st_mode & S_IFMT {
        case S_IFDIR:
            let left = try FileManager.default.contentsOfDirectory(atPath: original.path).sorted()
            let right = try FileManager.default.contentsOfDirectory(atPath: copy.path).sorted()
            guard left == right else { throw OperationError.verificationFailed(original.path) }
            for name in left {
                try verifyCopy(
                    original.appendingPathComponent(name), copy.appendingPathComponent(name), control: control)
            }
        case S_IFLNK:
            let left = try FileManager.default.destinationOfSymbolicLink(atPath: original.path)
            let right = try FileManager.default.destinationOfSymbolicLink(atPath: copy.path)
            guard left == right else { throw OperationError.verificationFailed(original.path) }
        case S_IFREG:
            guard a.st_size == b.st_size,
                try Self.sha256(original, control: control) == Self.sha256(copy, control: control)
            else {
                throw OperationError.verificationFailed(original.path)
            }
        default:
            break
        }
    }

    static func sha256(_ url: URL, control: OperationControl?) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            try control?.waitWhilePaused()
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize()
    }

    // MARK: - Undo

    private func applyUndo(_ record: UndoRecord, control: OperationControl) async throws {
        control.update { $0.itemsTotal = record.steps.count }
        for step in record.steps.reversed() {
            try Task.checkCancellation()
            switch step {
            case .trashCreated(let url, let fileID):
                guard Self.lstatInfo(url.path) != nil else { break }
                guard Self.fileID(url) == fileID else {
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
                try await moveItem(at: trashed, to: original)
            }
            control.update { $0.itemsDone += 1 }
        }
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

    static func fileID(_ url: URL) -> UInt64 {
        lstatInfo(url.path).map { UInt64($0.st_ino) } ?? 0
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

/// The item a replacement sent to the Trash, filled in by the copy's last step.
private final class ReplacedItem {
    var trashed: URL?
}
