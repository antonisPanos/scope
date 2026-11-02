import Foundation
import Synchronization
import Testing

@testable import Scope
@testable import ScopeEngine

@MainActor struct InfoCancellationTests {
    @Test func closingInfoCancelsTheCountAndIgnoresLateProgress() async throws {
        let state = Mutex((started: false, cancelled: false, progress: (@Sendable (FolderSize) -> Void)?.none))
        let engine = FileEngine(pathGuard: .readOnly)
        // Read metadata only; the injected counter never walks this folder.
        let item = try await engine.item(at: URL(fileURLWithPath: NSTemporaryDirectory()))
        let model = InfoModel(item: item, engine: engine) { _, progress in
            state.withLock {
                $0.started = true
                $0.progress = progress
            }
            defer { state.withLock { $0.cancelled = Task.isCancelled } }
            try await Task.sleep(for: .seconds(60))
            return FolderSize()
        }
        model.load()
        for _ in 0..<500 {
            if state.withLock({ $0.started }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.withLock { $0.started })
        #expect(model.isCounting)
        model.cancel()
        #expect(!model.isCounting)
        for _ in 0..<500 {
            if state.withLock({ $0.cancelled }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.withLock { $0.cancelled })
        let lateProgress = state.withLock { $0.progress }
        lateProgress?(FolderSize())
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.folderSize == nil)
        #expect(!model.isCounting)
    }

    @Test func cancellingBeforeLoadStartsDoesNotStartAStaleCount() async throws {
        let engine = FileEngine(pathGuard: .readOnly)
        let item = try await engine.item(at: URL(fileURLWithPath: NSTemporaryDirectory()))
        let model = InfoModel(item: item, engine: engine)
        model.load()
        model.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!model.isCounting)
        #expect(model.folderSize == nil)
        #expect(model.details == nil)
    }
}
