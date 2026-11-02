import Foundation
import Testing

@testable import ScopeEngine

struct ArchiveCancellationTests {
    @Test func cancelledPreflightDoesNotOpenTheReader() async throws {
        let sandbox = try Sandbox()
        let archive = try sandbox.write("input.zip", "unused")
        let calls = Recorded<Bool>()
        var engine = sandbox.engine
        engine.archiveReaders = CountingReaders(calls: calls)
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.extractionSpaceProblem(archive)
        }
        #expect(await worker.value == nil)
        #expect(calls.all.count == 0)
    }

    @Test func preflightChecksCancellationBetweenHeaders() async throws {
        let sandbox = try Sandbox()
        let archive = try sandbox.write("input.zip", "unused")
        let calls = Recorded<Bool>()
        var engine = sandbox.engine
        engine.archiveReaders = CountingReaders(calls: calls, cancelOnHeader: true)
        let worker = Task { await engine.extractionSpaceProblem(archive) }
        #expect(await worker.value == nil)
        // One open and one header, rather than all 500 headers.
        #expect(calls.all.count == 2)
    }

    @Test(arguments: SilentPhase.allCases)
    func cancellationInterruptsEveryXPCWait(phase: SilentPhase) async throws {
        let sandbox = try Sandbox()
        let archive = try sandbox.write("input.bin", "unused")
        let reached = Recorded<Bool>()
        let service = ServiceHarness(SilentListener(phase: phase, reached: reached))
        var engine = sandbox.engine
        engine.archiveReaders = service.readers(timeout: .seconds(60))
        let worker = Task { try await OperationHarness(engine: engine).run(.extract(archive)) }
        for _ in 0..<500 {
            if !reached.all.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!reached.all.isEmpty)
        let start = ContinuousClock.now
        worker.cancel()
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(try sandbox.names() == ["input.bin"])
    }
}

private struct CountingReaders: ArchiveReaderOpening {
    let calls: Recorded<Bool>
    var cancelOnHeader = false

    func open(_ archive: FileHandle, singleFile: Bool) throws(ArchiveReadError) -> any ArchiveReading {
        calls.append(true)
        return CountingReader(calls: calls, cancelOnHeader: cancelOnHeader)
    }
}

private final class CountingReader: ArchiveReading {
    let calls: Recorded<Bool>
    let cancelOnHeader: Bool

    init(calls: Recorded<Bool>, cancelOnHeader: Bool) {
        self.calls = calls
        self.cancelOnHeader = cancelOnHeader
    }

    func nextEntry() throws(ArchiveReadError) -> ArchiveEntry? {
        calls.append(true)
        let count = calls.all.count
        if cancelOnHeader { withUnsafeCurrentTask { $0?.cancel() } }
        return count <= 501 ? ArchiveEntry(name: "item-\(count)", kind: .file, size: 0) : nil
    }

    func readData(upTo limit: Int) throws(ArchiveReadError) -> Data { Data() }
}

enum SilentPhase: Sendable, CaseIterable { case open, entry, data }

private final class SilentListener: NSObject, NSXPCListenerDelegate, Sendable {
    let phase: SilentPhase
    let reached: Recorded<Bool>

    init(phase: SilentPhase, reached: Recorded<Bool>) {
        self.phase = phase
        self.reached = reached
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = ArchiveService.interface
        connection.exportedObject = SilentService(phase: phase, reached: reached)
        connection.resume()
        return true
    }
}

private final class SilentService: NSObject, ArchiveServiceProtocol, Sendable {
    let phase: SilentPhase
    let reached: Recorded<Bool>

    init(phase: SilentPhase, reached: Recorded<Bool>) {
        self.phase = phase
        self.reached = reached
    }

    func open(_ archive: FileHandle, singleFile: Bool, reply: @escaping @Sendable (Data?) -> Void) {
        if phase == .open { reached.append(true) } else { reply(nil) }
    }

    func nextEntry(reply: @escaping @Sendable (Data) -> Void) {
        if phase == .entry {
            reached.append(true)
        } else {
            reply(
                try! JSONEncoder().encode(ServiceReply<ArchiveEntry?>.success(ArchiveEntry(name: "leaf", kind: .file))))
        }
    }

    func readData(upTo limit: Int, reply: @escaping @Sendable (Data?, Data?) -> Void) {
        reached.append(true)
    }
}
