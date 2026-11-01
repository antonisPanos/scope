import Dispatch

/// Where the engine's blocking file system work runs.
///
/// Copies, listings, hashing, archives and search make blocking system calls.
/// On Swift's concurrency pool, which has one thread per core, a few slow
/// disks, paused copies or a search could take every thread and stall
/// everything else that awaits, folder listings included. This executor runs
/// that work on a concurrent dispatch queue instead, which adds threads when
/// the ones it has are blocked, and leaves the pool free.
final class IOExecutor: TaskExecutor {
    static let shared = IOExecutor()
    static let label = "com.antonispanos.scope.engine.io"

    private let queue = DispatchQueue(label: Self.label, qos: .userInitiated, attributes: .concurrent)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

/// Runs `body` on the engine's I/O threads. Child tasks it starts, such as a
/// search's folder scans, run there too. Calls nested inside one another stay
/// on the same threads without hopping.
func onIOThreads<T, Failure: Error>(_ body: () async throws(Failure) -> T) async throws(Failure) -> T {
    try await withTaskExecutorPreference(IOExecutor.shared, operation: body)
}
