import Foundation
import Synchronization
import Testing

@testable import Scope
@testable import ScopeEngine

@MainActor struct InfoModelTests {
    private func model(counter: @escaping InfoModel.FolderCounter) async throws -> InfoModel {
        let engine = FileEngine(pathGuard: .readOnly)
        let item = try await engine.item(at: TestPaths.packages)
        return InfoModel(item: item, engine: engine, countFolder: counter)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test func loadingAndProgressAreProvisionalForEveryTotal() async throws {
        let callback = Mutex<(@Sendable (FolderSize) -> Void)?>(nil)
        let model = try await model { _, progress in
            callback.withLock { $0 = progress }
            try await Task.sleep(for: .seconds(60))
            return FolderSize()
        }
        defer { model.cancel() }
        model.load()
        #expect(model.countState == .counting(nil))
        #expect(InfoView(model: model).generalRows.first?.1 == "Calculating…")
        try await waitUntil { callback.withLock { $0 != nil } }
        let partial = FolderSize(bytes: 100, allocatedBytes: 4096, items: 3)
        callback.withLock { $0 }?(partial)
        try await waitUntil { model.folderSize == partial }
        let rows = Array(InfoView(model: model).generalRows.prefix(3))
        #expect(rows.map(\.0) == ["Size", "On disk", "Contains"])
        #expect(rows.allSatisfy { $0.1.hasSuffix(" so far…") })
        #expect(model.countMessage == nil)
    }

    @Test(arguments: [false, true])
    func completedResultsRejectLateProgress(incomplete: Bool) async throws {
        let callback = Mutex<(@Sendable (FolderSize) -> Void)?>(nil)
        let result = FolderSize(bytes: 100, allocatedBytes: 4096, items: 3, isIncomplete: incomplete)
        let model = try await model { _, progress in
            callback.withLock { $0 = progress }
            progress(FolderSize())
            return result
        }
        defer { model.cancel() }
        model.load()
        try await waitUntil { !model.isCounting }
        #expect(model.countState == .completed(result))
        #expect(model.countMessage == (incomplete ? "Incomplete — some items couldn’t be read." : nil))
        let rows = Array(InfoView(model: model).generalRows.prefix(3))
        #expect(rows.allSatisfy { $0.1.contains("(partial)") == incomplete })
        callback.withLock { $0 }?(FolderSize())
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.countState == .completed(result))
    }

    @Test(arguments: [false, true])
    func failuresStopLoadingAndRetainOnlyPartialTotals(afterProgress: Bool) async throws {
        let callback = Mutex<(@Sendable (FolderSize) -> Void)?>(nil)
        let partial = FolderSize(bytes: 100, allocatedBytes: 4096, items: 3)
        let error = CocoaError(.fileReadNoPermission)
        let model = try await model { _, progress in
            callback.withLock { $0 = progress }
            if afterProgress { progress(partial) }
            // Fail immediately: the progress task may still be queued on MainActor.
            throw error
        }
        defer { model.cancel() }
        model.load()
        try await waitUntil { !model.isCounting }
        #expect(model.countState == .failed(error.localizedDescription, partial: afterProgress ? partial : nil))
        #expect(model.countMessage?.contains("Couldn’t calculate size.") == true)
        #expect(model.countMessage?.contains(error.localizedDescription) == true)
        let rows = InfoView(model: model).generalRows
        if afterProgress {
            #expect(rows.prefix(3).allSatisfy { $0.1.hasSuffix(" (partial)") })
        } else {
            #expect(rows.first?.1 == "Couldn’t calculate size")
        }
        callback.withLock { $0 }?(FolderSize())
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.folderSize == (afterProgress ? partial : nil))
    }

    @Test func cancellationIsSilentAndRejectsLateProgress() async throws {
        let callback = Mutex<(@Sendable (FolderSize) -> Void)?>(nil)
        let partial = FolderSize(bytes: 100, items: 3)
        let model = try await model { _, progress in
            callback.withLock { $0 = progress }
            progress(partial)
            try await Task.sleep(for: .seconds(60))
            return FolderSize()
        }
        model.load()
        try await waitUntil { model.folderSize == partial }
        model.cancel()
        callback.withLock { $0 }?(FolderSize())
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.countState == .cancelled(partial))
        #expect(model.countMessage == nil)
    }

    @Test func aCounterCancellationIsNotReportedAsAFailure() async throws {
        let model = try await model { _, _ in throw CancellationError() }
        defer { model.cancel() }
        model.load()
        try await waitUntil { !model.isCounting }
        #expect(model.countState == .cancelled(nil))
        #expect(model.countMessage == nil)
        #expect(InfoView(model: model).generalRows.first?.1 == "Cancelled")
    }

    @Test func reloadClearsOldTotalsAndRejectsThePreviousCounter() async throws {
        let callbacks = Mutex<[@Sendable (FolderSize) -> Void]>([])
        let first = FolderSize(bytes: 100, items: 3)
        let model = try await model { _, progress in
            let attempt = callbacks.withLock {
                $0.append(progress)
                return $0.count
            }
            if attempt == 1 { return first }
            try await Task.sleep(for: .seconds(60))
            return FolderSize()
        }
        defer { model.cancel() }
        model.load()
        try await waitUntil { model.countState == .completed(first) && model.details != nil }
        #expect(model.details?.folderItemCount == nil)
        model.load()
        #expect(model.countState == .counting(nil))
        #expect(model.folderSize == nil)
        #expect(model.details == nil)
        try await waitUntil { callbacks.withLock { $0.count == 2 } }
        let staleProgress = callbacks.withLock { $0[0] }
        staleProgress(FolderSize())
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.countState == .counting(nil))
        let currentProgress = callbacks.withLock { $0[1] }
        currentProgress(first)
        try await waitUntil { model.folderSize == first }
    }
}
