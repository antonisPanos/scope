import Foundation

extension FileEngine {
    /// Validated read targets for UI handoff to Quick Look or another app.
    /// Resolution happens on the I/O executor, never during UI callbacks.
    public func readableURLs(_ urls: [URL]) async -> [URL] {
        await onIOThreads {
            readValidationHook?()
            var result: [URL] = []
            for url in urls {
                if Task.isCancelled { break }
                if let target = try? pathGuard.checkTarget(url) { result.append(target) }
            }
            return result
        }
    }

    /// Watcher setup resolves the path and opens filesystem resources.
    public func folderEvents(at url: URL) async throws -> FolderEvents {
        try await onIOThreads {
            try Task.checkCancellation()
            readValidationHook?()
            return try FolderWatcher.events(in: url, pathGuard: pathGuard)
        }
    }
}
