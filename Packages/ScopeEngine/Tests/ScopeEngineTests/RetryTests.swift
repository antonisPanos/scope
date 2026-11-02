import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

/// When an item fails partway (a read error, a failed verification), the
/// operation asks: try again, skip it, or stop. The engine's read fault makes
/// chosen files fail, as a bad disk would.
@Suite(.serialized) struct RetryTests {
    let source: TestVolume
    let disk: TestVolume

    init() throws {
        source = try TestVolume(name: "ScopeRetryA")
        disk = try TestVolume(name: "ScopeRetryB")
    }

    /// An engine whose reads of files named `bad` fail `times` times.
    private func engine(failing bad: String, times: Int) -> FileEngine {
        var engine = FileEngine(pathGuard: .restricted(to: [source.mountPoint, disk.mountPoint]))
        let left = Mutex(times)
        engine.readFault = { path in
            guard (path as NSString).lastPathComponent == bad else { return nil }
            return left.withLock { left in
                guard left > 0 else { return nil }
                left -= 1
                return EIO
            }
        }
        return engine
    }

    @discardableResult
    private func run(
        _ engine: FileEngine, _ kind: FileOperation.Kind, answers: [(FailureChoice, Bool)]
    ) async throws -> [ItemFailure] {
        let asked = Mutex<[ItemFailure]>([])
        try await engine.run(
            FileOperation(kind), control: OperationControl(), undo: UndoRecorder(),
            resolveConflict: { _ in (.stop, false) },
            resolveFailure: { failure in
                asked.withLock { asked in
                    asked.append(failure)
                    return answers[min(asked.count, answers.count) - 1]
                }
            })
        return asked.withLock { $0 }
    }

    @Test func tryAgainCopiesTheItemOnTheNextAttempt() async throws {
        try source.write("a.txt", "a")
        try source.write("folder/bad.bin", "data")
        let engine = engine(failing: "bad.bin", times: 1)
        let asked = try await run(
            engine, .copy([source.url("a.txt"), source.url("folder")], into: disk.work), answers: [(.retry, false)])
        #expect(asked.map(\.item.lastPathComponent) == ["folder"])
        #expect(try disk.read("folder/bad.bin") == "data")
        #expect(try disk.names() == ["a.txt", "folder"])
    }

    @Test func skipLeavesNothingOfTheItemAndGoesOn() async throws {
        try source.write("bad.bin", "data")
        try source.write("b.txt", "b")
        let engine = engine(failing: "bad.bin", times: 5)
        let kind = FileOperation.Kind.copy([source.url("bad.bin"), source.url("b.txt")], into: disk.work)
        try await run(engine, kind, answers: [(.skip, false)])
        #expect(try disk.names() == ["b.txt"])
    }

    @Test func stopEndsWithTheErrorAndKeepsTheSource() async throws {
        try source.write("bad.bin", "data")
        let engine = engine(failing: "bad.bin", times: 5)
        await #expect(throws: FileEngineError.self) {
            try await run(engine, .move([source.url("bad.bin")], into: disk.work), answers: [(.stop, false)])
        }
        #expect(try source.read("bad.bin") == "data")
        #expect(try disk.names() == [])
    }

    @Test func aFailedReplacementKeepsTheExistingItemUntilItWorks() async throws {
        try source.write("bad.bin", "new")
        try disk.write("bad.bin", "old")
        let engine = engine(failing: "bad.bin", times: 1)
        let existing = disk.url("bad.bin").path
        let seen = Mutex<[String]>([])
        try await engine.run(
            FileOperation(.copy([source.url("bad.bin")], into: disk.work)), control: OperationControl(),
            undo: UndoRecorder(), resolveConflict: { _ in (.replace, false) },
            resolveFailure: { _ in
                // While the question is open, the old file is still in place.
                let now = (try? String(contentsOfFile: existing, encoding: .utf8)) ?? "missing"
                seen.withLock { $0.append(now) }
                return (.retry, false)
            })
        #expect(seen.withLock { $0 } == ["old"])
        #expect(try disk.read("bad.bin") == "new")
    }

    @Test func skipAllAsksOnce() async throws {
        for name in ["bad.bin", "x.txt"] { try source.write("one/\(name)", name) }
        for name in ["bad.bin", "y.txt"] { try source.write("two/\(name)", name) }
        let engine = engine(failing: "bad.bin", times: 10)
        let asked = try await run(
            engine, .copy([source.url("one"), source.url("two")], into: disk.work), answers: [(.skip, true)])
        #expect(asked.count == 1)
        #expect(try disk.names() == [])
    }

    @Test func withoutAnAnswerItStopsAsBefore() async throws {
        try source.write("bad.bin", "data")
        let engine = engine(failing: "bad.bin", times: 1)
        await #expect(throws: FileEngineError.self) {
            try await engine.run(
                FileOperation(.copy([source.url("bad.bin")], into: disk.work)), control: OperationControl(),
                undo: UndoRecorder()
            ) { _ in (.stop, false) }
        }
    }

    @Test func onlyErrorsAnotherTryCanFixAreAsked() {
        #expect(FailurePolicy.isRetryable(FileEngineError.system(operation: "Read", path: "/x", code: EIO)))
        #expect(FailurePolicy.isRetryable(OperationError.verificationFailed("/x")))
        #expect(!FailurePolicy.isRetryable(CancellationError()))
        #expect(!FailurePolicy.isRetryable(OperationError.stoppedByUser))
        #expect(!FailurePolicy.isRetryable(FileEngineError.cannotCopyIntoItself("/x")))
    }
}
