import Foundation

/// Compression receives values/bytes, not paths or writable descriptors.
/// A command starts work; readOutput drains it with bounded backpressure.
@objc public protocol ArchiveWriterServiceProtocol {
    func openWriting(_ format: String, reply: @escaping @Sendable (Data?) -> Void)
    func writeEntry(_ entry: Data, reply: @escaping @Sendable (Data?) -> Void)
    func writeChunk(_ data: Data, reply: @escaping @Sendable (Data?) -> Void)
    func endEntry(reply: @escaping @Sendable (Data?) -> Void)
    func finishWriting(reply: @escaping @Sendable (Data?) -> Void)
    func readOutput(reply: @escaping @Sendable (Data, Bool, Data?) -> Void)
}

@objc protocol ArchiveCodecServiceProtocol: ArchiveServiceProtocol, ArchiveWriterServiceProtocol {}

extension ArchiveService {
    public static var writerInterface: NSXPCInterface { NSXPCInterface(with: ArchiveWriterServiceProtocol.self) }
    static var codecInterface: NSXPCInterface { NSXPCInterface(with: ArchiveCodecServiceProtocol.self) }
}

extension ArchiveServiceHandler {
    func openWriting(_ format: String, reply: @escaping @Sendable (Data?) -> Void) {
        writing.open(format, reply: reply)
    }
    func writeEntry(_ entry: Data, reply: @escaping @Sendable (Data?) -> Void) {
        writing.entry(entry, reply: reply)
    }
    func writeChunk(_ data: Data, reply: @escaping @Sendable (Data?) -> Void) {
        writing.chunk(data, reply: reply)
    }
    func endEntry(reply: @escaping @Sendable (Data?) -> Void) {
        writing.endEntry(reply: reply)
    }
    func finishWriting(reply: @escaping @Sendable (Data?) -> Void) {
        writing.finish(reply: reply)
    }
    func readOutput(reply: @escaping @Sendable (Data, Bool, Data?) -> Void) {
        writing.readOutput(reply: reply)
    }
}

/// The codec runs on its own queue. XPC callbacks stay available to drain
/// output even while libarchive is blocked on the bounded output buffer.
final class ArchiveWriterService: @unchecked Sendable {
    let output = ArchiveWriterOutput()
    private let factory: any ArchiveWriterOpening
    private let queue = DispatchQueue(
        label: "com.antonispanos.scope.archive.writer", qos: .utility, autoreleaseFrequency: .workItem)
    private let replies = DispatchQueue(
        label: "com.antonispanos.scope.archive.output", qos: .utility, autoreleaseFrequency: .workItem)
    // Only accessed on queue.
    private var writer: (any ArchiveWriting)?

    init(factory: any ArchiveWriterOpening) { self.factory = factory }

    func open(_ raw: String, reply: @escaping @Sendable (Data?) -> Void) {
        guard let format = ArchiveFormat(rawValue: raw) else {
            reply(encodeWriteFailure(.failed("Unsupported archive format.")))
            return
        }
        enqueue(reply) { (service: ArchiveWriterService) throws(ArchiveWriteError) in
            guard service.writer == nil else { throw .failed("The writer is already open.") }
            let output = service.output
            service.writer = try service.factory.open(format: format, control: nil) {
                (data: Data) throws(ArchiveWriteError) in try output.append(data)
            }
        }
    }

    func entry(_ data: Data, reply: @escaping @Sendable (Data?) -> Void) {
        guard data.count <= 64 * 1024, let entry = try? JSONDecoder().decode(ArchiveEntry.self, from: data) else {
            reply(encodeWriteFailure(.failed("Invalid archive entry.")))
            return
        }
        enqueue(reply) { (service: ArchiveWriterService) throws(ArchiveWriteError) in
            try service.requireWriter().beginEntry(entry)
        }
    }

    func chunk(_ data: Data, reply: @escaping @Sendable (Data?) -> Void) {
        guard data.count <= FileEngine.chunkSize else {
            reply(encodeWriteFailure(.failed("Archive input chunk is too large.")))
            return
        }
        // Own input storage before acknowledging receipt and scheduling work.
        let payload = data.withUnsafeBytes { Data($0) }
        enqueue(reply) { (service: ArchiveWriterService) throws(ArchiveWriteError) in
            try service.requireWriter().writeData(payload)
        }
    }

    func endEntry(reply: @escaping @Sendable (Data?) -> Void) {
        enqueue(reply) { (service: ArchiveWriterService) throws(ArchiveWriteError) in
            try service.requireWriter().finishEntry()
        }
    }

    func finish(reply: @escaping @Sendable (Data?) -> Void) {
        enqueue(reply) { (service: ArchiveWriterService) throws(ArchiveWriteError) in
            try service.requireWriter().finish()
        }
    }

    func readOutput(reply: @escaping @Sendable (Data, Bool, Data?) -> Void) {
        // Wait off the XPC callback queue, and reply as soon as data or
        // completion arrives. Small entries incur no polling delay.
        replies.async { [output] in
            let result = output.take(wait: true)
            reply(result.data, result.complete, result.failure.map(encodeWriteFailure))
        }
    }

    func cancel() {
        output.cancel()
        queue.async { [self] in
            writer?.cancel()
            writer = nil
        }
    }

    private func requireWriter() throws(ArchiveWriteError) -> any ArchiveWriting {
        guard let writer else { throw .failed("The archive writer is not open.") }
        return writer
    }

    private func enqueue(
        _ reply: @escaping @Sendable (Data?) -> Void,
        operation: @escaping @Sendable (ArchiveWriterService) throws(ArchiveWriteError) -> Void
    ) {
        do throws(ArchiveWriteError) {
            try output.start()
            queue.async { [self] in
                do throws(ArchiveWriteError) {
                    try operation(self)
                    output.complete(nil)
                } catch {
                    output.complete(error)
                }
            }
            reply(nil)
        } catch {
            reply(encodeWriteFailure(error))
        }
    }

}

/// At most one chunk is buffered, regardless of archive size or the amount
/// a codec emits while closing. Cancellation wakes a blocked codec callback.
final class ArchiveWriterOutput: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var buffer = Data()
    private var running = false
    private var stopped = false
    private var failure: ArchiveWriteError?

    init(capacity: Int = FileEngine.chunkSize) { self.capacity = capacity }

    func start() throws(ArchiveWriteError) {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped, !running, buffer.isEmpty, failure == nil else {
            throw .failed("Invalid archive command order.")
        }
        running = true
    }

    func append(_ data: Data) throws(ArchiveWriteError) {
        guard data.count <= capacity else { throw .failed("Archive output chunk is too large.") }
        condition.lock()
        defer { condition.unlock() }
        while !stopped, buffer.count + data.count > capacity { condition.wait() }
        guard !stopped else { throw .failed("The archive connection was closed.") }
        buffer.append(data)
        condition.broadcast()
    }

    func take(wait: Bool = false) -> (data: Data, complete: Bool, failure: ArchiveWriteError?) {
        condition.lock()
        defer { condition.unlock() }
        while wait, running, buffer.isEmpty, !stopped { condition.wait() }
        let data = buffer
        buffer = Data()
        condition.broadcast()
        return (data, !running, failure)
    }

    func complete(_ error: ArchiveWriteError?) {
        condition.lock()
        defer { condition.unlock() }
        running = false
        failure = error
        condition.broadcast()
    }

    func cancel() {
        condition.lock()
        defer { condition.unlock() }
        stopped = true
        running = false
        buffer = Data()
        failure = .failed("The archive connection was closed.")
        condition.broadcast()
    }
}

func encodeWriteFailure(_ error: ArchiveWriteError) -> Data {
    (try? JSONEncoder().encode(error)) ?? Data()
}
