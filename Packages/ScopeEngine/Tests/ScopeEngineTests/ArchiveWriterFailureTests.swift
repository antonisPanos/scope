import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

struct ArchiveWriterFailureTests {
    @Test(arguments: [
        WriterFault.garbled, .oversized, .disconnected, .neverCompletes, .failed, .noOutput, .flood,
    ])
    func aBrokenWriterLeavesNoArchive(fault: WriterFault) async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("input.txt", "safe input")
        let before = try TreeSnapshot(sandbox.root)
        let reached = Recorded<Bool>()
        let service = ServiceHarness(BrokenWriterListener(fault: fault, reached: reached))
        var engine = sandbox.engine
        engine.archiveWriters = service.writers(timeout: .milliseconds(300))
        await #expect(throws: OperationError.self) {
            try await OperationHarness(engine: engine).run(.compress([source], format: .zip))
        }
        #expect(try TreeSnapshot(sandbox.root) == before)
    }

    @Test func aSilentWriterCanBeCancelledWithoutWaitingForItsTimeout() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("input.txt", "safe input")
        let reached = Recorded<Bool>()
        let service = ServiceHarness(BrokenWriterListener(fault: .silence, reached: reached))
        var engine = sandbox.engine
        engine.archiveWriters = service.writers()
        let worker = Task { try await OperationHarness(engine: engine).run(.compress([source], format: .zip)) }
        for _ in 0..<500 {
            if !reached.all.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!reached.all.isEmpty)
        let start = ContinuousClock.now
        worker.cancel()
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(try sandbox.names() == ["input.txt"])
    }

    @Test func pausedTimeDoesNotConsumeAnXPCReplyTimeout() async throws {
        let paused = Mutex(true)
        let entered = Recorded<Bool>()
        let result = Outcome<Int>()
        let worker = Task.detached(executorPreference: IOExecutor.shared) {
            entered.append(true)
            return result.wait(for: .milliseconds(50), isPaused: { paused.withLock { $0 } })
        }
        defer { result.finish(42) }
        while entered.all.isEmpty { await Task.yield() }
        try await Task.sleep(for: .milliseconds(200))
        result.finish(42)
        #expect(await worker.value == 42)
    }

    @Test(arguments: [false, true]) func pausesOnOutputThenResumesOrCancels(cancel: Bool) async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("input.txt", "safe input")
        let control = OperationControl()
        let first = PauseFlag()
        let completed = Mutex(false)
        var engine = sandbox.engine
        engine.archiveWriters = PausingWriters(base: ServiceHarness(ArchiveServiceListener()).writers(), first: first)
        let worker = Task {
            let result = try await OperationHarness(engine: engine).run(
                .compress([source], format: .zip), control: control)
            completed.withLock { $0 = true }
            return result
        }
        for _ in 0..<500 {
            if first.value.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(first.value.withLock { $0 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!completed.withLock { $0 })
        #expect(!sandbox.exists("input.txt.zip"))
        if cancel {
            worker.cancel()
            await #expect(throws: CancellationError.self) { try await worker.value }
            #expect(try sandbox.names() == ["input.txt"])
        } else {
            control.isPaused = false
            _ = try await worker.value
            #expect(sandbox.exists("input.txt.zip"))
        }
    }
}

private struct PausingWriters: ArchiveWriterOpening {
    let base: any ArchiveWriterOpening
    let first: PauseFlag

    func open(
        format: ArchiveFormat, control: OperationControl?, output: @escaping ArchiveDataSink
    )
        throws(ArchiveWriteError) -> any ArchiveWriting
    {
        let first = first
        return try base.open(format: format, control: control) { (data: Data) throws(ArchiveWriteError) in
            let pause = first.value.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            if pause { control?.isPaused = true }
            try output(data)
        }
    }
}

enum WriterFault: Sendable {
    case garbled, oversized, disconnected, neverCompletes, failed, noOutput, flood, silence
}

private final class BrokenWriterListener: NSObject, NSXPCListenerDelegate, Sendable {
    let fault: WriterFault
    let reached: Recorded<Bool>

    init(fault: WriterFault, reached: Recorded<Bool>) {
        self.fault = fault
        self.reached = reached
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = ArchiveService.writerInterface
        connection.exportedObject = BrokenWriter(connection: connection, fault: fault, reached: reached)
        connection.resume()
        return true
    }
}

private final class BrokenWriter: NSObject, ArchiveWriterServiceProtocol, @unchecked Sendable {
    let connection: NSXPCConnection
    let fault: WriterFault
    let reached: Recorded<Bool>
    private let reads = Mutex(0)

    init(connection: NSXPCConnection, fault: WriterFault, reached: Recorded<Bool>) {
        self.connection = connection
        self.fault = fault
        self.reached = reached
    }

    func openWriting(_ format: String, reply: @escaping @Sendable (Data?) -> Void) {
        if fault == .disconnected {
            connection.invalidate()
            return
        }
        reply(fault == .garbled ? Data("not JSON".utf8) : nil)
    }
    func writeEntry(_ entry: Data, reply: @escaping @Sendable (Data?) -> Void) { reply(nil) }
    func writeChunk(_ data: Data, reply: @escaping @Sendable (Data?) -> Void) { reply(nil) }
    func endEntry(reply: @escaping @Sendable (Data?) -> Void) { reply(nil) }
    func finishWriting(reply: @escaping @Sendable (Data?) -> Void) { reply(nil) }
    func readOutput(reply: @escaping @Sendable (Data, Bool, Data?) -> Void) {
        reached.append(true)
        switch fault {
        case .silence: return
        case .oversized: reply(Data(count: FileEngine.chunkSize + 1), true, nil)
        case .neverCompletes: reply(Data(), false, nil)
        case .flood: reply(Data(count: 64 * 1024), false, nil)
        case .failed:
            let first = reads.withLock { value in
                value += 1
                return value == 1
            }
            reply(
                first ? Data([0x50, 0x4b]) : Data(), true, first ? nil : encodeWriteFailure(.failed("Codec failed.")))
        default: reply(Data(), true, nil)
        }
    }
}

private final class PauseFlag: Sendable { let value = Mutex(false) }
