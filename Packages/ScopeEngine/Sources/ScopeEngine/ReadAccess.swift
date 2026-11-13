import Foundation

extension FileEngine {
    /// Available bytes on the guarded folder's volume. `statfs` is used here
    /// because Foundation can report zero for writable APFS image volumes.
    public func availableCapacity(at url: URL) async -> Int64? {
        await onIOThreads {
            guard let folder = try? pathGuard.checkTarget(url) else { return nil }
            var fileSystem = statfs()
            guard statfs(folder.path, &fileSystem) == 0 else { return nil }
            return Int64(clamping: UInt64(fileSystem.f_bavail) * UInt64(fileSystem.f_bsize))
        }
    }

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
