import Foundation

/// The app's compression codec. Only bounded values and bytes cross XPC;
/// all user-file reads, output writes and publication stay in FileEngine.
public struct XPCArchiveWriters: ArchiveWriterOpening {
    private let connect: @Sendable () -> NSXPCConnection
    private let timeout: Duration

    public init(timeout: Duration = .seconds(60), connect: @escaping @Sendable () -> NSXPCConnection) {
        self.connect = connect
        self.timeout = timeout
    }

    public static func embedded(_ serviceName: String) -> XPCArchiveWriters {
        XPCArchiveWriters { NSXPCConnection(serviceName: serviceName) }
    }

    public func open(
        format: ArchiveFormat, control: OperationControl?, output: @escaping ArchiveDataSink
    )
        throws(ArchiveWriteError) -> any ArchiveWriting
    {
        let connection = connect()
        connection.remoteObjectInterface = ArchiveService.writerInterface
        connection.resume()
        let writer = XPCArchiveWriter(connection: connection, timeout: timeout, control: control, output: output)
        try writer.perform { service, reply in service.openWriting(format.rawValue, reply: reply) }
        return writer
    }
}

final class XPCArchiveWriter: ArchiveWriting {
    private let connection: NSXPCConnection
    private let timeout: Duration
    private let control: OperationControl?
    private let output: ArchiveDataSink
    private var finished = false

    init(connection: NSXPCConnection, timeout: Duration, control: OperationControl?, output: @escaping ArchiveDataSink)
    {
        self.connection = connection
        self.timeout = timeout
        self.control = control
        self.output = output
    }

    deinit { connection.invalidate() }

    func beginEntry(_ entry: ArchiveEntry) throws(ArchiveWriteError) {
        guard let encoded = try? JSONEncoder().encode(entry), encoded.count <= 64 * 1024 else {
            throw .failed("The archive entry is too large.")
        }
        try perform { service, reply in service.writeEntry(encoded, reply: reply) }
    }

    func writeData(_ data: Data) throws(ArchiveWriteError) {
        guard data.count <= FileEngine.chunkSize else { throw .failed("Archive input chunk is too large.") }
        try perform { service, reply in service.writeChunk(data, reply: reply) }
    }

    func finishEntry() throws(ArchiveWriteError) {
        try perform { service, reply in service.endEntry(reply: reply) }
    }

    func finish() throws(ArchiveWriteError) {
        try perform { service, reply in service.finishWriting(reply: reply) }
        finished = true
        connection.invalidate()
    }

    func cancel() {
        finished = true
        connection.invalidate()
    }

    func perform(
        _ send: (any ArchiveWriterServiceProtocol, @escaping @Sendable (Data?) -> Void) -> Void
    )
        throws(ArchiveWriteError)
    {
        guard !finished else { throw .failed("The archive writer is closed.") }
        do throws(ArchiveWriteError) {
            try archiveWriteCheckpoint(control)
            let error: Data? = try call(send)
            if let error { throw Self.decode(error) }
            var idle: Duration = .zero
            while true {
                // Paused time is outside the timeout measurement. A full
                // service buffer blocks the codec until the parent resumes.
                try archiveWriteCheckpoint(control)
                let start = ContinuousClock.now
                let chunk: Output = try call { service, reply in
                    service.readOutput { reply(Output(data: $0, complete: $1, error: $2)) }
                }
                let data = chunk.data
                guard data.count <= FileEngine.chunkSize else {
                    throw .failed("The archive writer returned an oversized output chunk.")
                }
                if let error = chunk.error { throw Self.decode(error) }
                if !data.isEmpty {
                    try output(data)
                    idle = .zero
                }
                if chunk.complete { return }
                if data.isEmpty {
                    Thread.sleep(forTimeInterval: 0.005)
                    idle += ContinuousClock.now - start
                    guard idle < timeout else { throw .failed("The archive writer stopped responding.") }
                }
            }
        } catch {
            cancel()
            throw error
        }
    }

    private struct Output: Sendable {
        let data: Data
        let complete: Bool
        let error: Data?
    }

    private func call<Value: Sendable>(
        _ send: (any ArchiveWriterServiceProtocol, @escaping @Sendable (Value) -> Void) -> Void
    ) throws(ArchiveWriteError) -> Value {
        try archiveWriteCheckpoint(control)
        let outcome = Outcome<Value>()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in outcome.finish(nil) }
        guard let service = proxy as? any ArchiveWriterServiceProtocol else {
            throw .failed("The archive writer stopped unexpectedly.")
        }
        send(service) { outcome.finish($0) }
        guard let result = outcome.wait(for: timeout, isPaused: { [control] in control?.isPaused == true }) else {
            throw .failed(
                outcome.timedOut ? "The archive writer took too long." : "The archive writer stopped unexpectedly.")
        }
        return result
    }

    private static func decode(_ data: Data) -> ArchiveWriteError {
        guard data.count <= 64 * 1024, let error = try? JSONDecoder().decode(ArchiveWriteError.self, from: data) else {
            return .failed("The archive writer returned an invalid reply.")
        }
        return error
    }
}
