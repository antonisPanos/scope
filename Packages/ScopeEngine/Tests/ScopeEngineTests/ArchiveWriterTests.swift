import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

struct ArchiveWriterTests {
    @Test(arguments: ArchiveFormat.allCases, [false, true])
    func largeInputsRoundTripInBoundedChunks(format: ArchiveFormat, service: Bool) async throws {
        let sandbox = try Sandbox()
        var data = Data(count: 6 * 1024 * 1024 + 19)
        data.withUnsafeMutableBytes { bytes in
            var state: UInt64 = 0x1234_5678_90ab_cdef
            for index in bytes.indices {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                bytes[index] = UInt8(truncatingIfNeeded: state)
            }
        }
        let source = try sandbox.write("input.bin", data)
        let chunks = Recorded<Int>()
        let harness = ServiceHarness(ArchiveServiceListener())
        var engine = sandbox.engine
        engine.archiveWriters = ObservedWriters(base: service ? harness.writers() : LibArchiveWriters(), chunks: chunks)
        engine.archiveReaders = harness.readers()
        let ops = OperationHarness(engine: engine)
        try await ops.run(.compress([source], format: format))
        let archive = source.appendingPathExtension(format.fileExtension)
        // Also verify interoperability with macOS's separate-process codec.
        #expect(try TestVolume.output("/usr/bin/tar", ["-xOf", archive.path, "input.bin"]) == data)
        try await ops.run(.extract(archive))
        #expect(try Data(contentsOf: sandbox.url("input 2.bin")) == data)
        #expect(chunks.all.count > 1)
        #expect(chunks.all.allSatisfy { $0 > 0 && $0 <= FileEngine.chunkSize })
    }

    @Test(arguments: [false, true]) func writerRejectsWrongEntryLengths(service: Bool) throws {
        let factory: any ArchiveWriterOpening =
            service
            ? ServiceHarness(ArchiveServiceListener()).writers() : LibArchiveWriters()
        let writer = try factory.open(format: .zip, control: nil) { _ in }
        defer { writer.cancel() }
        try writer.beginEntry(ArchiveEntry(name: "file", kind: .file, size: 3))
        try writer.writeData(Data([1]))
        #expect(throws: ArchiveWriteError.self) { try writer.finishEntry() }
    }

    @Test func outputBackpressureIsBoundedAndCancellationReleasesTheProducer() async throws {
        let output = ArchiveWriterOutput(capacity: 4)
        try output.start()
        try output.append(Data([1, 2, 3, 4]))
        let started = Mutex(false)
        let worker = Task.detached {
            started.withLock { $0 = true }
            do {
                try output.append(Data([5]))
                return false
            } catch { return true }
        }
        while !started.withLock({ $0 }) { await Task.yield() }
        output.cancel()
        #expect(await worker.value)
        let state = output.take()
        #expect(state.complete)
        #expect(state.data.isEmpty)
        #expect(state.failure != nil)
    }

    @Test func failedOutputIsNeverPublished() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("input.txt", "data")
        var engine = sandbox.engine
        engine.archiveWriters = ServiceHarness(ArchiveServiceListener()).writers()
        engine.writeFault = { _, _ in ENOSPC }
        await #expect(throws: OperationError.self) {
            try await OperationHarness(engine: engine).run(.compress([source], format: .zip))
        }
        #expect(try sandbox.names() == ["input.txt"])
    }

    @Test(arguments: [false, true]) func anOutputReplyWakesForDataOrCancellation(cancel: Bool) async throws {
        let output = ArchiveWriterOutput(capacity: 4)
        try output.start()
        let worker = Task.detached { output.take(wait: true) }
        if cancel { output.cancel() } else { try output.append(Data([1, 2])) }
        let result = await worker.value
        #expect(result.data == (cancel ? Data() : Data([1, 2])))
        #expect(result.complete == cancel)
        #expect((result.failure != nil) == cancel)
        output.cancel()
    }
}

private struct ObservedWriters: ArchiveWriterOpening {
    let base: any ArchiveWriterOpening
    let chunks: Recorded<Int>

    func open(
        format: ArchiveFormat, control: OperationControl?, output: @escaping ArchiveDataSink
    )
        throws(ArchiveWriteError) -> any ArchiveWriting
    {
        let chunks = chunks
        return try base.open(format: format, control: control) { (data: Data) throws(ArchiveWriteError) in
            chunks.append(data.count)
            try output(data)
        }
    }
}
