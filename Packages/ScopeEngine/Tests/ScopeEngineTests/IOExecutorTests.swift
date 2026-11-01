import Dispatch
import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

@Suite struct IOExecutorTests {
    private static func currentQueueLabel() -> String {
        String(cString: __dispatch_queue_get_label(nil))
    }

    @Test func blockedEngineWorkLeavesThePoolFree() async throws {
        // Twice as many blocked jobs as the pool has threads.
        let blockers = ProcessInfo.processInfo.activeProcessorCount * 2
        let gate = DispatchSemaphore(value: 0)
        let started = AsyncStream.makeStream(of: Void.self)
        let jobs = (0..<blockers).map { _ in
            Task {
                await onIOThreads {
                    started.continuation.yield()
                    // Released below; the timeout only keeps a failure from hanging.
                    _ = gate.wait(timeout: .now() + 5)
                }
            }
        }
        var running = 0
        for await _ in started.stream {
            running += 1
            if running == blockers { break }
        }

        // A task with no executor preference runs on the pool.
        let before = ContinuousClock.now
        await Task.detached {}.value
        #expect(ContinuousClock.now - before < .seconds(1))

        for _ in 0..<blockers { gate.signal() }
        for job in jobs { await job.value }
    }

    @Test func engineWorkRunsOnTheIOThreads() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "hello")
        let labels = Mutex<Set<String>>([])
        try await sandbox.engine.copyItem(at: sandbox.url("a.txt"), to: sandbox.url("b.txt")) { _ in
            let label = Self.currentQueueLabel()
            labels.withLock { _ = $0.insert(label) }
        }
        #expect(labels.withLock { $0 } == [IOExecutor.label])
    }
}
