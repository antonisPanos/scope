import Dispatch
import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

/// Shared by the blocked jobs, which each run in a task of their own.
private final class Counter: Sendable {
    let state = Mutex((running: 0, most: 0))
}

@Suite struct IOExecutorTests {
    private static func currentQueueLabel() -> String {
        String(cString: __dispatch_queue_get_label(nil))
    }

    /// Blocks the calling thread, as a slow disk would. Released by the
    /// test; the timeout only keeps a failure from hanging.
    private static func block(on gate: DispatchSemaphore) {
        _ = gate.wait(timeout: .now() + 30)
    }

    @Test func blockedEngineWorkGetsThreadsBeyondThePool() async throws {
        // Twice as many blocked jobs as the pool has threads, all blocked at
        // once. On the pool, only one per core could run; the rest would wait.
        // (Timing a pool task instead would measure the other suites, which
        // block pool threads themselves.)
        let blockers = ProcessInfo.processInfo.activeProcessorCount * 2
        let gate = DispatchSemaphore(value: 0)
        let counts = Counter()
        let started = AsyncStream.makeStream(of: Void.self)
        let jobs = (0..<blockers).map { _ in
            Task {
                await onIOThreads {
                    counts.state.withLock {
                        $0.running += 1
                        $0.most = max($0.most, $0.running)
                    }
                    started.continuation.yield()
                    Self.block(on: gate)
                    counts.state.withLock { $0.running -= 1 }
                }
            }
        }
        var running = 0
        for await _ in started.stream {
            running += 1
            if running == blockers { break }
        }
        for _ in 0..<blockers { gate.signal() }
        for job in jobs { await job.value }
        #expect(counts.state.withLock { $0.most } == blockers)
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
