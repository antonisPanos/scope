import CryptoKit
import Foundation
import os.signpost

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
                undo.add(.moveBack(from: renamed, to: try pathGuard.checkLocation(item), fileID: Self.fileID(renamed)))
            case .newFolder(let folder, let name):
                let target = try uniqueName(name, in: try pathGuard.checkWriteLocation(folder), style: .numbered)
                try await createFolder(at: target)
                undo.add(.trashCreated(target, fileID: Self.fileID(target)))
            case .trash(let items):
                try await trash(items, control: control, undo: undo, confirm: confirmPermanentDeletion)
            case .deletePermanently(let items):
                try await deleteForGood(items, control: control, undo: undo, confirm: confirmPermanentDeletion)
            case .setTag(let items, let tag, let applied):
                try setTag(tag, applied: applied, on: items, control: control)
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

    private struct TransferContext {
        let moving: Bool
        let control: OperationControl
        let undo: UndoRecorder
        let parents: [(MergeDirectory, MergeDirectory)]
        let remainingOutside: Int
    }

    private func transfer(
        _ items: [URL], into folder: URL, moving: Bool, control: OperationControl,
        undo: UndoRecorder, conflicts: inout ConflictPolicy, failures: inout FailurePolicy
    ) async throws {
        let signpostID = OSSignpostID(log: StressTrace.signpostLog)
        os_signpost(.begin, log: StressTrace.signpostLog, name: "Transfer", signpostID: signpostID)
        defer { os_signpost(.end, log: StressTrace.signpostLog, name: "Transfer", signpostID: signpostID) }
        control.trace("measurement-start")
        control.beginTransferReport(notStarted: items.count)
        let destination = try pathGuard.checkWriteLocation(folder)
        let sources = try items.map { try pathGuard.checkLocation($0) }
        // Keep the initial measurement for each top-level item. Measuring again
        // after a failure can observe a different tree and corrupt the totals.
        let measurements = try sources.map { try measure([$0]) }
        control.update {
            $0.bytesTotal = measurements.reduce(0) { $0 + $1.bytes }
            $0.itemsTotal = measurements.reduce(0) { $0 + $1.items }
        }
        try preflight(sources, into: destination, moving: moving)
        control.trace("transfer-start")
        try await transferItems(
            sources, measurements: measurements, into: destination, moving: moving,
            control: control, undo: undo, conflicts: &conflicts, failures: &failures)
    }

    /// Executes measured items against the existing operation's report and progress.
    /// The caller owns initial measurement and preflight, so nested work must not reset them.
    private func transferItems(
        _ sources: [URL], measurements: [(bytes: Int64, items: Int)], into destination: URL,
        moving: Bool, control: OperationControl, undo: UndoRecorder,
        conflicts: inout ConflictPolicy, failures: inout FailurePolicy
    ) async throws {
        for (index, pair) in zip(sources, measurements).enumerated() {
            try await transferItem(
                pair.0, measurement: pair.1, into: destination,
                context: TransferContext(
                    moving: moving, control: control, undo: undo, parents: [],
                    remainingOutside: sources.count - index - 1),
                conflicts: &conflicts, failures: &failures)
        }
    }

    private func transferItem(
        _ source: URL, measurement: (bytes: Int64, items: Int), into destination: URL,
        context: TransferContext,
        conflicts: inout ConflictPolicy, failures: inout FailurePolicy
    ) async throws {
        let moving = context.moving
        let control = context.control
        let undo = context.undo
        let parents = context.parents
        func validateParents() throws {
            for (source, destination) in parents {
                try source.validate(pathGuard: pathGuard)
                try destination.validate(pathGuard: pathGuard)
            }
        }
        try Task.checkCancellation()
        try control.waitWhilePaused()
        try validateParents()
        control.setNotStarted(context.remainingOutside)
        var outcome: TransferOutcome.Result = .failed("Stopped before completion")
        var transferredBytes: Int64 = 0
        var reportedMeasurement = measurement
        defer {
            control.recordOutcome(
                TransferOutcome(
                    item: source, items: reportedMeasurement.items, bytes: reportedMeasurement.bytes, result: outcome),
                transferredBytes: transferredBytes)
        }
        do {
            let sameFolder = source.deletingLastPathComponent().path == destination.path
            if moving && sameFolder {
                outcome = .skipped("Already in the destination folder")
                control.removePending(bytes: measurement.bytes, items: measurement.items)
                return
            }
            var target = destination.appendingPathComponent(source.lastPathComponent)
            var replacing = false
            if Self.lstatInfo(target.path) != nil {
                if sameFolder {
                    // Pasting a copy into its own folder makes "name copy", like Finder.
                    target = try uniqueName(source.lastPathComponent, in: destination, style: .copy)
                } else {
                    // lstat describes the link itself, including dangling links.
                    func kind(_ url: URL) -> ConflictItemKind {
                        guard let info = Self.lstatInfo(url.path) else { return .unknown }
                        switch info.st_mode & S_IFMT {
                        case S_IFREG: return .file
                        case S_IFDIR: return .directory
                        case S_IFLNK: return .symbolicLink
                        default: return .other
                        }
                    }
                    // Both folders are pinned before asking, so a merge notices
                    // either one being swapped while the question is open. A
                    // folder that can't be pinned is just not offered a merge,
                    // and the other choices never depend on the pins.
                    var mergePins: (MergeDirectory, MergeDirectory)?
                    if Self.mergeEligible(source, target) {
                        mergePins = try? (
                            MergeDirectory(source, pathGuard: pathGuard, writable: false),
                            MergeDirectory(target, pathGuard: pathGuard, writable: true)
                        )
                    }
                    let conflict = Conflict(
                        incoming: source, existing: target, incomingModified: Self.modified(source),
                        existingModified: Self.modified(target), incomingKind: kind(source), existingKind: kind(target),
                        canMerge: mergePins != nil)
                    var choice = try await conflicts.resolve(conflict)
                    try validateParents()
                    let replaceIfOlder = choice == .replaceIfOlder
                    if choice == .replaceIfOlder {
                        choice = Self.isOlderFile(target, than: source) ? .replace : .skip
                    }
                    switch choice {
                    case .merge:
                        guard !moving, let (incoming, existing) = mergePins,
                            Self.mergeEligible(source, target),
                            !Self.isInside(target.path, source.path), !Self.isInside(source.path, target.path)
                        else { throw CocoaError(.featureUnsupported) }
                        try incoming.validate(pathGuard: pathGuard)
                        try existing.validate(pathGuard: pathGuard)
                        let names = try incoming.names(pathGuard: pathGuard)
                        let children = names.map { source.appendingPathComponent($0) }
                        let childMeasurements = try children.map { try measure([$0]) }
                        let skippedBefore = control.transferReport?.skippedCount ?? 0
                        reportedMeasurement = (bytes: 0, items: 1)
                        control.update { $0.itemsDone += 1 }
                        control.setNotStarted(context.remainingOutside + children.count)
                        for (index, child) in children.enumerated() {
                            control.setNotStarted(context.remainingOutside + children.count - index)
                            try incoming.validate(pathGuard: pathGuard)
                            try existing.validate(pathGuard: pathGuard)
                            try await transferItem(
                                child, measurement: childMeasurements[index], into: target,
                                context: TransferContext(
                                    moving: false, control: control, undo: undo,
                                    parents: parents + [(incoming, existing)],
                                    remainingOutside: context.remainingOutside + children.count - index - 1),
                                conflicts: &conflicts, failures: &failures)
                        }
                        outcome =
                            (control.transferReport?.skippedCount ?? 0) > skippedBefore
                            ? .incomplete("Some children were skipped") : .completed
                        return
                    case .skip, .replaceIfOlder:
                        outcome = .skipped(replaceIfOlder ? "Existing item is not older" : "Skipped by choice")
                        control.removePending(bytes: measurement.bytes, items: measurement.items)
                        return
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

            outcome = try await performTransfer(
                TransferTarget(
                    source: source, target: target, destination: destination,
                    replacing: replacing, measurement: measurement),
                context: context, failures: &failures, transferredBytes: &transferredBytes)
        } catch {
            outcome = .failed(TransferReport.diagnostic(error))
            throw error
        }
    }

    private struct TransferTarget {
        let source: URL
        let target: URL
        let destination: URL
        let replacing: Bool
        let measurement: (bytes: Int64, items: Int)
    }

    private func performTransfer(
        _ item: TransferTarget, context: TransferContext, failures: inout FailurePolicy,
        transferredBytes: inout Int64
    ) async throws -> TransferOutcome.Result {
        let source = item.source
        let target = item.target
        let destination = item.destination
        let replacing = item.replacing
        let measurement = item.measurement
        let moving = context.moving
        let control = context.control
        let undo = context.undo
        let parents = context.parents
        func validateParents() throws {
            for (source, destination) in parents {
                try source.validate(pathGuard: pathGuard)
                try destination.validate(pathGuard: pathGuard)
            }
        }
        let sameDisk = try sameOperationVolume(source, destination)
        if moving && sameDisk {
            // A rename is instant, so the existing item is trashed just
            // before it, and put back if the rename fails.
            var trashed: URL?
            var moved = false
            var lastFailure = ""
            while !moved {
                if replacing, Self.lstatInfo(target.path) != nil { trashed = try trashItemNow(target) }
                do {
                    try await moveItem(at: source, to: target)
                    moved = true
                } catch {
                    if let trashed { restoreReplaced(trashed, to: target, undo: undo) }
                    trashed = nil
                    lastFailure = TransferReport.diagnostic(error)
                    guard try await failures.retry(source, after: error) else { break }
                }
            }
            guard moved else {
                control.removePending(bytes: measurement.bytes, items: measurement.items)
                return .failedAndSkipped(lastFailure)
            }
            if let trashed { undo.add(.putBack(trashed: trashed, original: target)) }
            undo.add(.moveBack(from: target, to: source, fileID: Self.fileID(target)))
            control.update {
                $0.bytesDone += measurement.bytes
                $0.itemsDone += measurement.items
                $0.currentItem = source.lastPathComponent
            }
            return .completed
        }

        // The copy is written under a partial name. Only when it is complete
        // (and, for a move, verified) does a replaced item go to the Trash,
        // right before the copy is renamed into its place.
        let replaced = ReplacedItem()
        var verifiedSource: VerifiedSource?
        let existing = replacing ? target : nil
        let placeCopy: (URL, URL) throws -> Void = { original, partial in
            try validateParents()
            if moving {
                control.update { $0.currentItem = "Verifying \(original.lastPathComponent)" }
                control.trace("verification-start")
                self.copyTestOptions.boundary?(.beforeVerification, original, partial)
                verifiedSource = try self.verifyCopy(original, partial, control: control)
                self.copyTestOptions.boundary?(.afterVerification, original, partial)
                control.trace("verification-complete")
            }
            if let existing, Self.lstatInfo(existing.path) != nil {
                try validateParents()
                replaced.trashed = try self.trashItemNow(existing)
            }
        }
        // A failed attempt leaves nothing behind and puts a replaced item
        // back, so the item can be tried again from the start.
        let before = control.progress
        var copied = false
        var lastFailure = ""
        while !copied {
            do {
                try validateParents()
                try copyTracked(
                    source, to: target, control: control, replacingExisting: replacing,
                    recoveryAction: moving ? .move : .copy,
                    validateParents: { input, output in
                        try validateParents()
                        if let (incoming, existing) = parents.last {
                            try incoming.validateChildParent(input)
                            try existing.validateChildParent(output)
                        }
                    }, beforePlacing: placeCopy
                )
                control.trace("published")
                copied = true
            } catch let error as PublishedCopyFinalizationError {
                if let trashed = replaced.trashed {
                    undo.add(replacementStep(trashed, target: target, parents: parents))
                }
                undo.add(.trashCreated(target, fileID: error.publishedIdentity))
                if moving {
                    throw OperationError.copyFinalizationFailed(
                        source.lastPathComponent, error.localizedDescription)
                }
                throw error
            } catch {
                control.trace("copy-attempt-failed")
                if let trashed = replaced.trashed {
                    do {
                        try validateParents()
                    } catch {
                        undo.add(replacementStep(trashed, target: target, parents: parents))
                        throw error
                    }
                    if let parent = parents.last?.1 {
                        do {
                            try placeBack(trashed, at: target, expectedParent: parent.fileIdentity)
                        } catch {
                            undo.add(replacementStep(trashed, target: target, parents: parents))
                            throw error
                        }
                    } else {
                        restoreReplaced(trashed, to: target, undo: undo)
                    }
                }
                replaced.trashed = nil
                verifiedSource = nil
                control.update {
                    $0.bytesDone = before.bytesDone
                    $0.itemsDone = before.itemsDone
                }
                lastFailure = TransferReport.diagnostic(error)
                guard try await failures.retry(source, after: error) else { break }
            }
        }
        guard copied else {
            control.removePending(bytes: measurement.bytes, items: measurement.items)
            return .failedAndSkipped(lastFailure)
        }
        transferredBytes = max(0, control.progress.bytesDone - before.bytesDone)
        if let trashed = replaced.trashed { undo.add(replacementStep(trashed, target: target, parents: parents)) }
        undo.add(.trashCreated(target, fileID: Self.fileID(target)))
        if moving {
            control.trace("source-retirement-start")
            copyTestOptions.boundary?(.beforeSourceRetirement, source, target)
            guard let verifiedSource else { throw OperationError.copiedSourceChanged(source.path) }
            let trashed = try retireVerifiedSource(source, evidence: verifiedSource)
            if let trashed { undo.add(.putBack(trashed: trashed, original: source)) }
            control.trace("source-retired")
        }
        return .completed
    }

    /// Never follow a final link or infer eligibility when package metadata is unavailable.
    static func mergeEligible(_ incoming: URL, _ existing: URL) -> Bool {
        func ordinaryDirectory(_ url: URL) -> Bool {
            guard let info = lstatInfo(url.path), info.st_mode & S_IFMT == S_IFDIR,
                let values = try? url.resourceValues(forKeys: [.isPackageKey]),
                let isPackage = values.isPackage
            else { return false }
            return !isPackage
        }
        return ordinaryDirectory(incoming) && ordinaryDirectory(existing)
    }

    /// Puts back an item that was trashed to make room for a replacement that
    /// then failed. If that isn't possible, the operation's undo can still do it.
    private func replacementStep(_ trashed: URL, target: URL, parents: [(MergeDirectory, MergeDirectory)]) -> UndoStep {
        if let parent = parents.last?.1 {
            return .putBackInParent(trashed: trashed, original: target, parent: parent.fileIdentity)
        }
        return .putBack(trashed: trashed, original: target)
    }

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

    private func placeBack(_ trashed: URL, at original: URL, expectedParent: FileIdentity) throws {
        let from = try CopyLocation(checked: pathGuard.checkPutBack(trashed))
        let to = try CopyLocation(checked: pathGuard.checkWriteLocation(original))
        let parent = try to.parent.info()
        guard UInt64(parent.st_dev) == expectedParent.device, UInt64(parent.st_ino) == expectedParent.inode,
            UInt32(parent.st_mode & S_IFMT) == expectedParent.kind
        else { throw OperationError.undoNotPossible("The original merge folder has changed.") }
        try to.validateParent(pathGuard: pathGuard)
        let source = try from.info()
        guard from.renameExclusively(into: to.parent, as: to.name, isDirectory: source.st_mode & S_IFMT == S_IFDIR)
        else { throw FileEngineError.posix("Put back", original.path) }
    }

    /// Copies one item and adds its progress to the operation's totals.
    private func copyTracked(
        _ source: URL, to target: URL, control: OperationControl, replacingExisting: Bool = false,
        recoveryAction: RecoveryJournal.Action = .copy,
        validateParents: ((CopyDescriptor, CopyDescriptor) throws -> Void)? = nil,
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
            }, replacingExisting: replacingExisting, recoveryAction: recoveryAction, validateParents: validateParents,
            beforePlacing: beforePlacing)
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
            do {
                try copyTracked(source, to: target, control: control)
            } catch let error as PublishedCopyFinalizationError {
                undo.add(.trashCreated(target, fileID: error.publishedIdentity))
                throw error
            }
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
    @discardableResult
    func verifyCopy(_ original: URL, _ copy: URL, control: OperationControl?) throws -> VerifiedSource {
        var hash = SHA256()
        try verifyCopy(
            CopyLocation(checked: pathGuard.checkLocation(original)),
            CopyLocation(checked: pathGuard.checkWriteLocation(copy)), control: control, hash: &hash)
        return VerifiedSource(fingerprint: Data(hash.finalize()))
    }

    private func verifyCopy(
        _ original: CopyLocation, _ copy: CopyLocation, control: OperationControl?, hash: inout SHA256
    ) throws {
        try Task.checkCancellation()
        let a = try original.info()
        let b = try copy.info()
        guard a.st_mode & S_IFMT == b.st_mode & S_IFMT else {
            throw OperationError.verificationFailed(original.path)
        }
        let version = SourceVersion(a)
        version.append(to: &hash)
        var sourceDescriptor: CopyDescriptor?
        switch a.st_mode & S_IFMT {
        case S_IFDIR:
            let source = try original.open(O_RDONLY | O_DIRECTORY, matching: a)
            sourceDescriptor = source
            let destination = try copy.open(O_RDONLY | O_DIRECTORY, matching: b)
            let left = try CopyLocation.names(in: source, path: original.path).sorted()
            let right = try CopyLocation.names(in: destination, path: copy.path).sorted()
            guard left == right else { throw OperationError.verificationFailed(original.path) }
            Self.appendNames(left, to: &hash)
            for name in left {
                try verifyCopy(
                    original.child(name, in: source), copy.child(name, in: destination), control: control, hash: &hash)
            }
            guard try CopyLocation.names(in: source, path: original.path).sorted() == left else {
                throw OperationError.verificationFailed(original.path)
            }
        case S_IFLNK:
            sourceDescriptor = try original.open(O_SYMLINK, matching: a)
            guard try original.linkTarget() == copy.linkTarget() else {
                throw OperationError.verificationFailed(original.path)
            }
        case S_IFREG:
            let source = try original.open(O_RDONLY, matching: a)
            sourceDescriptor = source
            let destination = try copy.open(O_RDONLY, matching: b)
            guard a.st_size == b.st_size,
                try Self.sha256(source, control: control) == Self.sha256(destination, control: control)
            else { throw OperationError.verificationFailed(original.path) }
        default: throw OperationError.verificationFailed(original.path)
        }
        guard version == SourceVersion(try original.info()),
            try sourceDescriptor.map({ version == SourceVersion(try $0.info()) }) ?? true
        else { throw OperationError.verificationFailed(original.path) }
        verifiedItemHook?(original.path)
    }

    /// The evidence is gathered around each verified read, not in a later
    /// tree snapshot. Only the resulting digest is retained.
    struct VerifiedSource {
        let fingerprint: Data
    }

    struct SourceVersion: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let flags: UInt32
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            mode = info.st_mode
            flags = info.st_flags
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }

        func append(to hash: inout SHA256) {
            let fields = [
                String(device), String(inode), String(mode), String(flags), String(size),
                String(modifiedSeconds), String(modifiedNanoseconds),
                String(changedSeconds), String(changedNanoseconds),
            ]
            for field in fields { FileEngine.appendFingerprintField(field, to: &hash) }
        }
    }

    /// Length-prefix each UTF-8 field so names and numeric fields cannot be
    /// confused with delimiters or with fields from a different tree.
    private static func appendFingerprintField(_ value: String, to hash: inout SHA256) {
        let bytes = Data(value.utf8)
        hash.update(data: Data("\(bytes.count):".utf8))
        hash.update(data: bytes)
    }

    private static func appendNames(_ names: [String], to hash: inout SHA256) {
        appendFingerprintField(String(names.count), to: &hash)
        for name in names { appendFingerprintField(name, to: &hash) }
    }

    private func fingerprintSource(_ location: CopyLocation, hash: inout SHA256) throws {
        let info = try location.info()
        let version = SourceVersion(info)
        version.append(to: &hash)
        let descriptor: CopyDescriptor
        if info.st_mode & S_IFMT == S_IFDIR {
            let directory = try location.open(O_RDONLY | O_DIRECTORY, matching: info)
            descriptor = directory
            let names = try CopyLocation.names(in: directory, path: location.path).sorted()
            Self.appendNames(names, to: &hash)
            for name in names {
                try fingerprintSource(location.child(name, in: directory), hash: &hash)
            }
            guard try CopyLocation.names(in: directory, path: location.path).sorted() == names else {
                throw OperationError.copiedSourceChanged(location.path)
            }
        } else if info.st_mode & S_IFMT == S_IFREG {
            descriptor = try location.open(O_RDONLY, matching: info)
        } else if info.st_mode & S_IFMT == S_IFLNK {
            descriptor = try location.open(O_SYMLINK, matching: info)
        } else {
            throw OperationError.copiedSourceChanged(location.path)
        }
        guard SourceVersion(try descriptor.info()) == version, SourceVersion(try location.info()) == version else {
            throw OperationError.copiedSourceChanged(location.path)
        }
    }

    func retireVerifiedSource(_ source: URL, evidence: VerifiedSource) throws -> URL? {
        let target: URL
        do {
            target = try pathGuard.checkModifiable(source)
            var hash = SHA256()
            try fingerprintSource(CopyLocation(checked: target), hash: &hash)
            guard Data(hash.finalize()) == evidence.fingerprint else {
                throw OperationError.copiedSourceChanged(source.path)
            }
        } catch {
            throw OperationError.copiedSourceChanged(source.path)
        }
        // Foundation's Trash API takes a path, not a checked descriptor. A
        // replacement between this final check and Trash remains possible.
        return try moveToTrash(target)
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
                guard Self.sameItem(Self.fileID(url), fileID) else {
                    throw OperationError.undoNotPossible("“\(url.lastPathComponent)” has been replaced since.")
                }
                _ = try await trashItem(at: url)
            case .moveBack(let from, let to, let made):
                guard Self.lstatInfo(from.path) != nil else {
                    throw OperationError.undoNotPossible("“\(from.lastPathComponent)” isn't there anymore.")
                }
                guard Self.sameItem(Self.fileID(from), made) else {
                    throw OperationError.undoNotPossible("“\(from.lastPathComponent)” has been replaced since.")
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
            case .putBackInParent(let trashed, let original, let expected):
                try placeBack(trashed, at: original, expectedParent: expected)
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
        // Generated names are shortened to the disk's name limit, keeping
        // the " copy 2" part and, where it fits, the extension.
        let marker = style == .copy ? " copy" : ""
        for number in 1...10_000 {
            try Task.checkCancellation()
            let tail = number == 1 ? marker : "\(marker) \(number)"
            let candidate = Self.fittingName(base, tail, extension: suffix)
            let url = folder.appendingPathComponent(candidate)
            if Self.lstatInfo(url.path) == nil { return try pathGuard.checkWriteLocation(url) }
        }
        throw FileEngineError.destinationExists(folder.appendingPathComponent(name).path)
    }

    /// The item's identity and version now; all zero when it is missing.
    /// Directory versions compare descendants, excluding directory times so
    /// later operations undone first can restore the original state.
    static func fileID(_ url: URL) -> FileIdentity {
        guard let info = lstatInfo(url.path) else { return FileIdentity(inode: 0, modified: 0, size: 0) }
        if info.st_mode & S_IFMT == S_IFDIR {
            return FileIdentity(
                inode: UInt64(info.st_ino), modified: 0, size: 0, device: UInt64(info.st_dev),
                kind: UInt32(info.st_mode & S_IFMT), directoryVersion: try? DirectoryVersion.read(url, expected: info))
        }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return FileIdentity(
            inode: UInt64(info.st_ino), modified: modified, size: Int64(info.st_size), device: UInt64(info.st_dev),
            kind: UInt32(info.st_mode & S_IFMT))
    }

    private static func sameItem(_ now: FileIdentity, _ made: FileIdentity) -> Bool {
        now.inode != 0 && now.inode == made.inode && now.device == made.device && now.kind == made.kind
    }

    /// Files an undo would move to the Trash that were edited after the
    /// operation made them: same file, other modification time or size. A
    /// replaced or missing item isn't listed; undo handles those itself.
    static func changedSinceMade(_ record: UndoRecord) -> [URL] {
        record.steps.compactMap { step in
            guard case .trashCreated(let url, let made) = step else { return nil }
            let now = fileID(url)
            return sameItem(now, made)
                && (now != made || (made.kind == UInt32(S_IFDIR) && made.directoryVersion == nil)) ? url : nil
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
    private struct Key: Hashable {
        let incoming: ConflictItemKind
        let existing: ConflictItemKind
    }

    let resolver: ConflictResolver
    private var remembered: [Key: ConflictChoice] = [:]

    init(resolver: @escaping ConflictResolver) {
        self.resolver = resolver
    }

    mutating func resolve(_ conflict: Conflict) async throws -> ConflictChoice {
        try Task.checkCancellation()
        let key = Key(incoming: conflict.incomingKind, existing: conflict.existingKind)
        let known = key.incoming != .unknown && key.existing != .unknown
        if known, let choice = remembered[key], choice != .merge || conflict.canMerge { return choice }
        let (choice, applyToAll) = await resolver(conflict)
        // A cancel while the question was open wins over the answer.
        try Task.checkCancellation()
        guard choice != .merge || conflict.canMerge else { throw CocoaError(.featureUnsupported) }
        if applyToAll && known && choice != .stop { remembered[key] = choice }
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
        case FileEngineError.crossVolumeMoveNotSupported, FileEngineError.unsupportedItem: false
        default: true
        }
    }
}

/// The item a replacement sent to the Trash, filled in by the copy's last step.
private final class ReplacedItem {
    var trashed: URL?
}
