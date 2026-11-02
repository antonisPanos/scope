import Foundation

extension FileEngine {
    /// A folder's items in batches as they are read, so a big folder (or a
    /// slow disk) shows its first items at once. A batch is sent every
    /// `batchSize` items or every `interval`, whichever comes first; the
    /// last one holds the rest. It ends with an error, like
    /// `contentsOfDirectory(at:)`, when the folder can't be read, and stops
    /// reading as soon as the consumer stops iterating.
    public func listing(
        of folder: URL, includeHidden: Bool = true, batchSize: Int = 200, interval: Duration = .milliseconds(100)
    ) throws -> AsyncThrowingStream<[FileItem], Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [FileItem].self)
        let task = Task.detached(executorPreference: IOExecutor.shared, priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                readValidationHook?()
                let directory = try pathGuard.checkTarget(folder)
                try Self.readListing(
                    directory, includeHidden: includeHidden, batchSize: max(1, batchSize), interval: interval
                ) { batch in
                    continuation.yield(batch)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error is CancellationError ? nil : error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func readListing(
        _ directory: URL, includeHidden: Bool, batchSize: Int, interval: Duration,
        emit: ([FileItem]) -> Void
    ) throws {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        var failure: (any Error)?
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: FileItem.resourceKeys, options: options,
                errorHandler: { _, error in
                    failure = error
                    return false
                })
        else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: directory.path])
        }
        let clock = ContinuousClock()
        var sent = clock.now
        var batch: [FileItem] = []
        batch.reserveCapacity(batchSize)
        var read = 0
        for case let child as URL in enumerator {
            read += 1
            if read % 64 == 0 { try Task.checkCancellation() }
            guard let item = try? FileItem(url: child) else { continue }
            batch.append(item)
            if batch.count >= batchSize || clock.now - sent >= interval {
                emit(batch)
                batch.removeAll(keepingCapacity: true)
                sent = clock.now
            }
        }
        if let failure { throw failure }
        if !batch.isEmpty { emit(batch) }
    }
}
