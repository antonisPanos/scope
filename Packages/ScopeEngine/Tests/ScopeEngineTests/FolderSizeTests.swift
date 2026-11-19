import Dispatch
import Foundation
import Testing

@testable import ScopeEngine

@Suite struct FolderSizeTests {
    @Test func countsHiddenItemsPackagesAndLinksWithoutFollowingDescendantLinks() async throws {
        let sandbox = try Sandbox()
        try sandbox.mkdir("empty")
        #expect(try await sandbox.engine.folderSize(of: sandbox.url("empty")) == FolderSize())
        try sandbox.write("folder/.hidden", "hi")
        try sandbox.write("folder/App.app/Contents/data", "app")
        try sandbox.symlink("folder/loop", to: ".")
        try sandbox.symlink("folder/dangling", to: "missing")
        try sandbox.symlink("root-link", to: "folder")
        let size = try await sandbox.engine.folderSize(of: sandbox.url("folder"))
        #expect(size.items == 6)
        #expect(size.bytes == 5)
        #expect(!size.isIncomplete)
        #expect(try await sandbox.engine.folderSize(of: sandbox.url("root-link")) == size)
        let package = try await sandbox.engine.folderSize(of: sandbox.url("folder/App.app"))
        #expect(package.bytes == 3)
        #expect(package.items == 2)
        #expect(!package.isIncomplete)
    }

    @Test func invalidOrUnreadableRootsThrowWithoutPublishingZeroTotals() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("file", "file")
        try sandbox.write("denied/secret", "secret")
        #expect(chmod(sandbox.url("denied").path, 0) == 0)
        defer { chmod(sandbox.url("denied").path, 0o755) }
        let progress = Recorded<FolderSize>()
        for name in ["missing", "file", "denied"] {
            await #expect(throws: (any Error).self) {
                try await sandbox.engine.folderSize(of: sandbox.url(name)) { progress.append($0) }
            }
        }
        #expect(progress.all.isEmpty)
    }

    @Test func unreadableDescendantsLeaveExplicitlyIncompleteTotals() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("folder/readable", "yes")
        try sandbox.write("folder/denied/secret", "secret")
        #expect(chmod(sandbox.url("folder/denied").path, 0) == 0)
        defer { chmod(sandbox.url("folder/denied").path, 0o755) }
        let progress = Recorded<FolderSize>()
        let size = try await sandbox.engine.folderSize(of: sandbox.url("folder")) { progress.append($0) }
        #expect(size.bytes == 3)
        #expect(size.items == 2)
        #expect(size.isIncomplete)
        #expect(progress.all.last == size)
    }

    @Test func metadataFailureKeepsCountingOtherEntries() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("folder/good", "good")
        try sandbox.write("folder/disappeared", "gone")
        var engine = sandbox.engine
        engine.folderSizeEntryWillRead = { url in
            if url.lastPathComponent == "disappeared" { throw CocoaError(.fileReadNoSuchFile) }
        }
        let size = try await engine.folderSize(of: sandbox.url("folder"))
        #expect(size.items == 2)
        #expect(size.bytes == 4)
        #expect(size.isIncomplete)
    }

    @Test func disappearingRootNeverPublishesACachedSuccess() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("folder/only", "data")
        let folder = sandbox.url("folder")
        let moved = sandbox.url("moved")
        let progress = Recorded<FolderSize>()
        var engine = sandbox.engine
        engine.folderSizeEntryWillRead = { _ in
            try FileManager.default.moveItem(at: folder, to: moved)
        }
        await #expect(throws: (any Error).self) {
            try await engine.folderSize(of: folder) { progress.append($0) }
        }
        #expect(progress.all.isEmpty)
    }

    @Test func infoCanSkipTheUnusedImmediateChildCount() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("folder/file", "data")
        let preview = try await sandbox.engine.details(for: sandbox.url("folder"))
        let info = try await sandbox.engine.details(for: sandbox.url("folder"), includeFolderItemCount: false)
        #expect(preview.folderItemCount == 1)
        #expect(info.folderItemCount == nil)
        #expect(info.item == preview.item)
        #expect(info.permissions == preview.permissions)
    }

    @Test(arguments: [0, 1])
    func cancellationBeforeStartingNeverReadsOrPublishes(count: Int) async throws {
        let sandbox = try Sandbox()
        try sandbox.mkdir("folder")
        if count > 0 { try sandbox.write("folder/file", "x") }
        let reads = Recorded<URL>()
        let progress = Recorded<FolderSize>()
        var engine = sandbox.engine
        engine.folderSizeEntryWillRead = { reads.append($0) }
        let counter = engine
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await counter.folderSize(of: sandbox.url("folder")) { progress.append($0) }
        }
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(reads.all.isEmpty)
        #expect(progress.all.isEmpty)
    }

    @Test func cancellingASmallCountReachesTheIOWorkerBeforeAnotherRead() async throws {
        let sandbox = try Sandbox()
        for i in 0..<3 { try sandbox.write("folder/\(i)", "x") }
        let reads = Recorded<URL>()
        let progress = Recorded<FolderSize>()
        let started = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        var engine = sandbox.engine
        engine.folderSizeEntryWillRead = { url in
            reads.append(url)
            started.continuation.yield()
            _ = release.wait(timeout: .now() + 5)
        }
        let counter = engine
        let worker = Task {
            defer { started.continuation.finish() }
            return try await counter.folderSize(of: sandbox.url("folder")) { progress.append($0) }
        }
        for await _ in started.stream { break }
        worker.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(reads.all.count == 1)
        #expect(progress.all.isEmpty)
    }

    @Test func cancellationAtBatchedProgressPreventsTheNextRead() async throws {
        let sandbox = try Sandbox()
        for i in 0..<501 { try sandbox.write("folder/\(i)", "x") }
        let reads = Recorded<URL>()
        let progress = Recorded<FolderSize>()
        var engine = sandbox.engine
        engine.folderSizeEntryWillRead = { reads.append($0) }
        let counter = engine
        let worker = Task {
            try await counter.folderSize(of: sandbox.url("folder")) { size in
                progress.append(size)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(reads.all.count == 500)
        #expect(progress.all.map(\.items) == [500])
        #expect(progress.all.first?.bytes == 500)
    }

    @Test func cancellationDuringFinalProgressDoesNotReturnSuccess() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("folder/file", "x")
        let progress = Recorded<FolderSize>()
        let worker = Task {
            try await sandbox.engine.folderSize(of: sandbox.url("folder")) { size in
                progress.append(size)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(progress.all.map(\.items) == [1])
    }
}
