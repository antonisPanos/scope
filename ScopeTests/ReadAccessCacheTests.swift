import Foundation
import Synchronization
import Testing

@testable import Scope
@testable import ScopeEngine

@MainActor struct ReadAccessCacheTests {
    @Test func delayedValidationDoesNotBlockAMenuOrDragCallback() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let onMain = Mutex<[Bool]>([])
        let engine = await Task.detached {
            var engine = FileEngine(pathGuard: .restricted(to: [root]))
            engine.readValidationHook = {
                onMain.withLock { $0.append(Thread.isMainThread) }
                usleep(200_000)
            }
            return engine
        }.value
        let cache = ReadAccessCache(engine: engine)
        defer { cache.close() }
        let start = ContinuousClock.now
        #expect(!cache.permits(root))
        #expect(ContinuousClock.now - start < .milliseconds(100))
        // The main actor can keep processing UI while resolution is delayed.
        try await Task.sleep(for: .milliseconds(20))
        for _ in 0..<500 {
            if cache.permits(root) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cache.permits(root))
        #expect(onMain.withLock { $0 } == [false])
    }
}
