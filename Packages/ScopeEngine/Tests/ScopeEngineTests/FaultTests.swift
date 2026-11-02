import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

/// Copies and moves that fail or are cancelled partway, at every stage: the
/// items already done are complete, the one in progress leaves nothing
/// behind, the rest are untouched, and undo knows exactly what was done.
/// The engine's write fault stands in for a full or failing disk, and also
/// marks each stage (every chunk written) to cancel at.
@Suite(.serialized) struct FaultTests {
    let disk: TestVolume
    let other: TestVolume

    /// Three files of three chunks each, so a copy has nine write stages.
    static let names = ["a.bin", "b.bin", "c.bin"]
    static let fileSize = 2 * FileEngine.chunkSize + 1024

    init() throws {
        disk = try TestVolume(name: "ScopeFaultA")
        other = try TestVolume(name: "ScopeFaultB")
        for (index, name) in Self.names.enumerated() {
            try disk.write("src/\(name)", Data(repeating: UInt8(index + 1), count: Self.fileSize))
        }
    }

    private var sources: [URL] { Self.names.map { disk.url("src/\($0)") } }

    private func makeEngine(writeFault: (@Sendable (String, Int64) -> Int32?)? = nil) -> FileEngine {
        var engine = FileEngine(pathGuard: .restricted(to: [disk.mountPoint, other.mountPoint]))
        engine.writeFault = writeFault
        return engine
    }

    /// Every name under `folder`, at any depth, that is a partial copy.
    private func partials(in folder: URL) -> [String] {
        let all = FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []
        return all.filter { ($0 as NSString).lastPathComponent.hasPrefix(FileEngine.partialPrefix) }
    }

    /// Waits for `task`, failing the test instead of hanging when it doesn't
    /// end within `limit`.
    private func outcome(
        of task: Task<Void, Error>, within limit: Duration = .seconds(20)
    ) async -> Result<Void, Error>? {
        let result = Mutex<Result<Void, Error>?>(nil)
        Task {
            let value = await task.result
            result.withLock { $0 = value }
        }
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let done = result.withLock({ $0 }) { return done }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The operation was still running \(limit) after it was cancelled or failed")
        return nil
    }

    // MARK: - A full or failing disk

    @Test func aFullDiskKeepsWhatWasCopiedAndLeavesNoPartialItem() async throws {
        // The disk fills up during b.bin's second chunk.
        let engine = makeEngine { path, offset in
            path.hasSuffix("b.bin") && offset > 0 ? ENOSPC : nil
        }
        let undo = UndoRecorder()
        await #expect(throws: (any Error).self) {
            try await engine.run(
                FileOperation(.copy(sources, into: other.work)), control: OperationControl(), undo: undo
            ) { _ in (.stop, false) }
        }
        #expect(try other.names() == ["a.bin"])
        #expect(try Data(contentsOf: other.url("a.bin")) == Data(contentsOf: disk.url("src/a.bin")))
        #expect(partials(in: other.work).isEmpty)
        #expect(undo.recorded.count == 1)
        #expect(try disk.names("src") == Self.names)
    }

    @Test func aFailedReplacementPutsTheExistingItemBack() async throws {
        try other.write("b.bin", "the old b")
        let engine = makeEngine { path, offset in
            path.hasSuffix("b.bin") && offset > 0 ? EIO : nil
        }
        await #expect(throws: (any Error).self) {
            try await engine.run(
                FileOperation(.copy([disk.url("src/b.bin")], into: other.work)), control: OperationControl(),
                undo: UndoRecorder()
            ) { _ in (.replace, false) }
        }
        #expect(try other.read("b.bin") == "the old b")
        #expect(try other.names() == ["b.bin"])
        #expect(partials(in: other.work).isEmpty)
    }

    @Test func aFullDiskDuringAMoveKeepsEveryOriginalNotYetMoved() async throws {
        let engine = makeEngine { path, offset in
            path.hasSuffix("b.bin") && offset > 0 ? ENOSPC : nil
        }
        await #expect(throws: (any Error).self) {
            try await engine.run(
                FileOperation(.move(sources, into: other.work)), control: OperationControl(), undo: UndoRecorder()
            ) { _ in (.stop, false) }
        }
        // a.bin was copied, verified and then trashed at the source; b.bin and c.bin stay.
        #expect(try other.names() == ["a.bin"])
        #expect(try disk.names("src") == ["b.bin", "c.bin"])
        #expect(partials(in: other.work).isEmpty)
    }

    // MARK: - Cancel at every stage

    /// Runs `kind` and cancels it as the `stage`-th chunk is about to be written.
    private func cancel(_ kind: FileOperation.Kind, atWrite stage: Int) async -> (Result<Void, Error>?, UndoRecorder) {
        let handle = Mutex<Task<Void, Error>?>(nil)
        let writes = Mutex(0)
        let engine = makeEngine { _, _ in
            let count = writes.withLock { count in
                count += 1
                return count
            }
            if count == stage { handle.withLock { $0?.cancel() } }
            return nil
        }
        let undo = UndoRecorder()
        let ready = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            for await _ in ready.stream { break }
            try await engine.run(FileOperation(kind), control: OperationControl(), undo: undo) { _ in (.stop, false) }
        }
        handle.withLock { $0 = task }
        ready.continuation.yield()
        return (await outcome(of: task), undo)
    }

    @Test(arguments: 1...9) func cancellingACopyAtAnyChunk(stage: Int) async throws {
        let (result, undo) = await cancel(.copy(sources, into: other.work), atWrite: stage)
        guard case .failure(let error) = try #require(result) else {
            Issue.record("The copy finished although it was cancelled at write \(stage)")
            return
        }
        #expect(error is CancellationError)
        // Each file is three writes: the ones before the cancelled one are complete.
        let done = Self.names.prefix((stage - 1) / 3)
        #expect(try other.names() == Array(done))
        for name in done {
            #expect(try Data(contentsOf: other.url(name)) == Data(contentsOf: disk.url("src/\(name)")))
        }
        #expect(partials(in: other.work).isEmpty)
        #expect(undo.recorded.count == done.count)
        #expect(try disk.names("src") == Self.names)
    }

    @Test(arguments: 1...9) func cancellingAMoveBetweenDisksAtAnyChunk(stage: Int) async throws {
        let (result, _) = await cancel(.move(sources, into: other.work), atWrite: stage)
        guard case .failure(let error) = try #require(result) else {
            Issue.record("The move finished although it was cancelled at write \(stage)")
            return
        }
        #expect(error is CancellationError)
        let moved = Array(Self.names.prefix((stage - 1) / 3))
        #expect(try other.names() == moved)
        #expect(try disk.names("src") == Self.names.filter { !moved.contains($0) })
        #expect(partials(in: other.work).isEmpty)
    }

    @Test(arguments: 1...3) func cancellingATrashBetweenItems(stage: Int) async throws {
        let handle = Mutex<Task<Void, Error>?>(nil)
        let asked = Mutex(0)
        var configured = makeEngine()
        // Asked once per item, just before it goes: the stage to cancel at.
        configured.trashRefusal = { _ in
            let count = asked.withLock { count in
                count += 1
                return count
            }
            if count == stage { handle.withLock { $0?.cancel() } }
            return false
        }
        let engine = configured
        let sources = sources
        let undo = UndoRecorder()
        let ready = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            for await _ in ready.stream { break }
            try await engine.run(FileOperation(.trash(sources)), control: OperationControl(), undo: undo) { _ in
                (.stop, false)
            }
        }
        handle.withLock { $0 = task }
        ready.continuation.yield()
        let result = try #require(await outcome(of: task))
        // The item being asked about when the cancel came may still go; nothing after it does.
        let left = try disk.names("src")
        #expect(left.count >= Self.names.count - stage)
        #expect(undo.recorded.count == Self.names.count - left.count)
        if case .success = result { #expect(left.isEmpty) }
    }
}
