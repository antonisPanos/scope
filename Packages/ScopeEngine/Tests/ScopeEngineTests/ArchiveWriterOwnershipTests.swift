import Foundation
import Testing

@testable import ScopeEngine

struct ArchiveWriterOwnershipTests {
    @Test func theCodecOwnsInputAfterAcknowledgingTheCaller() throws {
        let probe = WriterInputProbe()
        let service = ArchiveWriterService(factory: probe)
        defer {
            service.cancel()
            probe.resume.signal()
        }
        service.open(ArchiveFormat.zip.rawValue) { _ in }
        #expect(service.output.take(wait: true).failure == nil)
        let entry = try JSONEncoder().encode(
            ArchiveEntry(name: "file", kind: .file, size: Int64(64 * 1024)))
        service.entry(entry) { _ in }
        #expect(service.output.take(wait: true).failure == nil)

        let storage = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: 16)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 1, count: 64 * 1024)
        let borrowed = Data(bytesNoCopy: storage, count: 64 * 1024, deallocator: .none)
        service.chunk(borrowed) { _ in }
        #expect(probe.entered.wait(timeout: .now() + 2) == .success)
        // The acknowledged caller's storage may change before the codec runs.
        // Its independently owned payload must retain the original bytes.
        storage.storeBytes(of: UInt8(9), as: UInt8.self)
        probe.resume.signal()
        #expect(service.output.take(wait: true).failure == nil)
        #expect(probe.received.all.first?.first == 1)

        service.endEntry { _ in }
        #expect(service.output.take(wait: true).failure == nil)
        service.finish { _ in }
        #expect(service.output.take(wait: true).failure == nil)
        service.cancel()
        #expect(probe.closed.wait(timeout: .now() + 2) == .success)
    }
}

private final class WriterInputProbe: ArchiveWriterOpening, Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0)
    let received = Recorded<Data>()

    func open(
        format: ArchiveFormat, control: OperationControl?, output: @escaping ArchiveDataSink
    )
        throws(ArchiveWriteError) -> any ArchiveWriting
    {
        return ProbedWriter(probe: self)
    }

}

private final class ProbedWriter: ArchiveWriting {
    let probe: WriterInputProbe
    init(probe: WriterInputProbe) { self.probe = probe }
    func beginEntry(_ entry: ArchiveEntry) throws(ArchiveWriteError) {}
    func writeData(_ data: Data) throws(ArchiveWriteError) {
        probe.entered.signal()
        guard probe.resume.wait(timeout: .now() + 2) == .success else { throw .failed("Test codec was not released.") }
        probe.received.append(data)
    }
    func finishEntry() throws(ArchiveWriteError) {}
    func finish() throws(ArchiveWriteError) {}
    func cancel() { probe.closed.signal() }
}
