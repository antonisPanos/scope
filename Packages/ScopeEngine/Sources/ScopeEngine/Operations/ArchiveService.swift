import Foundation
import Synchronization

// Reading archives in a separate, sandboxed process (an XPC service of the
// app). Archives come from anywhere, and a flaw in a parser then can't reach
// the user's files: this connection sees only the read-only archive the
// engine hands it. It sends back plain entries and data, which the engine
// checks and writes itself. The compression protocol is in ArchiveWriterService.

/// The messages between the app and the archive service. One connection
/// reads one archive. Replies carry `ServiceReply` values encoded as JSON,
/// except data chunks, which go as they are.
@objc public protocol ArchiveServiceProtocol {
    /// Starts reading `archive`. Replies with nil, or an encoded `ArchiveReadError`.
    func open(_ archive: FileHandle, singleFile: Bool, reply: @escaping @Sendable (Data?) -> Void)
    /// Replies with an encoded `ServiceReply<ArchiveEntry?>`.
    func nextEntry(reply: @escaping @Sendable (Data) -> Void)
    /// Replies with up to `limit` bytes of the current entry, or with nil
    /// data and an encoded `ArchiveReadError`.
    func readData(upTo limit: Int, reply: @escaping @Sendable (Data?, Data?) -> Void)
}

enum ServiceReply<Value: Codable>: Codable {
    case success(Value)
    case failure(ArchiveReadError)
}

public enum ArchiveService {
    /// The interface both ends of a connection use.
    public static var interface: NSXPCInterface {
        NSXPCInterface(with: ArchiveServiceProtocol.self)
    }
}

// MARK: - The service's side

/// Accepts connections in the service, each with its own codec state.
public final class ArchiveServiceListener: NSObject, NSXPCListenerDelegate, Sendable {
    private let readers: any ArchiveReaderOpening
    private let writers: any ArchiveWriterOpening

    public init(
        readers: any ArchiveReaderOpening = LibArchiveReaders(), writers: any ArchiveWriterOpening = LibArchiveWriters()
    ) {
        self.readers = readers
        self.writers = writers
    }

    public func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = ArchiveService.codecInterface
        let handler = ArchiveServiceHandler(readers: readers, writers: writers)
        connection.exportedObject = handler
        let writing = handler.writing
        connection.invalidationHandler = { writing.cancel() }
        connection.resume()
        return true
    }
}

/// Owns archive codec state for one connection.
final class ArchiveServiceHandler: NSObject, ArchiveCodecServiceProtocol, @unchecked Sendable {
    private let readers: any ArchiveReaderOpening
    /// Messages on a connection arrive one at a time, but the lock keeps that
    /// from being something to rely on.
    private let lock = NSLock()
    private var reader: (any ArchiveReading)?
    let writing: ArchiveWriterService

    init(readers: any ArchiveReaderOpening, writers: any ArchiveWriterOpening) {
        self.readers = readers
        writing = ArchiveWriterService(factory: writers)
    }

    func open(_ archive: FileHandle, singleFile: Bool, reply: @escaping @Sendable (Data?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        do {
            reader = try readers.open(archive, singleFile: singleFile)
            reply(nil)
        } catch {
            reply(Self.encode(error))
        }
    }

    func nextEntry(reply: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let result: ServiceReply<ArchiveEntry?>
        if let reader {
            do {
                result = .success(try reader.nextEntry())
            } catch {
                result = .failure(error)
            }
        } else {
            result = .failure(.damaged("The archive wasn't opened."))
        }
        reply((try? JSONEncoder().encode(result)) ?? Data())
    }

    func readData(upTo limit: Int, reply: @escaping @Sendable (Data?, Data?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let reader else { return reply(nil, Self.encode(.damaged("The archive wasn't opened."))) }
        do {
            reply(try reader.readData(upTo: min(max(0, limit), FileEngine.chunkSize)), nil)
        } catch {
            reply(nil, Self.encode(error))
        }
    }

    private static func encode(_ error: ArchiveReadError) -> Data {
        (try? JSONEncoder().encode(error)) ?? Data()
    }
}

// MARK: - The app's side

/// Reads archives through the archive service, one connection per archive.
/// Whatever the service sends back is checked: a reply that doesn't decode,
/// a chunk bigger than asked for, a crash or a hang all end the extraction
/// as a damaged archive.
public struct XPCArchiveReaders: ArchiveReaderOpening {
    private let connect: @Sendable () -> NSXPCConnection
    private let timeout: Duration

    /// `connect` makes a new, not yet resumed connection to the service.
    /// A call that takes longer than `timeout` stops the reading.
    public init(timeout: Duration = .seconds(60), connect: @escaping @Sendable () -> NSXPCConnection) {
        self.connect = connect
        self.timeout = timeout
    }

    /// The archive service embedded in the app, by its bundle identifier.
    public static func embedded(_ serviceName: String) -> XPCArchiveReaders {
        XPCArchiveReaders { NSXPCConnection(serviceName: serviceName) }
    }

    public func open(_ archive: FileHandle, singleFile: Bool) throws(ArchiveReadError) -> any ArchiveReading {
        let connection = connect()
        connection.remoteObjectInterface = ArchiveService.interface
        connection.resume()
        let reader = XPCArchiveReader(connection: connection, timeout: timeout)
        let failure: Data? = try reader.call { service, reply in
            service.open(archive, singleFile: singleFile, reply: reply)
        }
        if let failure { throw XPCArchiveReader.decodeError(failure) }
        return reader
    }
}

final class XPCArchiveReader: ArchiveReading {
    private let connection: NSXPCConnection
    private let timeout: Duration

    static let lost = "The archive couldn't be read: the reader stopped unexpectedly."

    init(connection: NSXPCConnection, timeout: Duration) {
        self.connection = connection
        self.timeout = timeout
    }

    deinit {
        connection.invalidate()
    }

    func nextEntry() throws(ArchiveReadError) -> ArchiveEntry? {
        let encoded: Data = try call { service, reply in service.nextEntry(reply: reply) }
        guard encoded.count <= AppleDouble.limit * 4 / 3 + 1024 * 1024 else { throw .damaged(Self.lost) }
        switch try? JSONDecoder().decode(ServiceReply<ArchiveEntry?>.self, from: encoded) {
        case .some(.success(let entry)): return entry
        case .some(.failure(let error)): throw error
        case nil: throw .damaged(Self.lost)
        }
    }

    func readData(upTo limit: Int) throws(ArchiveReadError) -> Data {
        let chunk: Chunk = try call { service, reply in
            service.readData(upTo: limit) { reply(Chunk(data: $0, failure: $1)) }
        }
        if let failure = chunk.failure { throw Self.decodeError(failure) }
        guard let data = chunk.data, data.count <= limit else { throw .damaged(Self.lost) }
        return data
    }

    private struct Chunk: Sendable {
        var data: Data?
        var failure: Data?
    }

    static func decodeError(_ encoded: Data) -> ArchiveReadError {
        (try? JSONDecoder().decode(ArchiveReadError.self, from: encoded)) ?? .damaged(lost)
    }

    /// Sends one message and waits for its reply. A lost connection or no
    /// reply within the timeout ends the connection and fails the call.
    func call<Value: Sendable>(
        _ send: (any ArchiveServiceProtocol, @escaping @Sendable (Value) -> Void) -> Void
    ) throws(ArchiveReadError) -> Value {
        guard !Task.isCancelled else {
            connection.invalidate()
            throw .damaged(Self.lost)
        }
        let outcome = Outcome<Value>()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in outcome.finish(nil) }
        guard let service = proxy as? any ArchiveServiceProtocol else { throw .damaged(Self.lost) }
        send(service) { outcome.finish($0) }
        guard let value = outcome.wait(for: timeout) else {
            connection.invalidate()
            throw .damaged(outcome.timedOut ? "Reading the archive took too long, so it was stopped." : Self.lost)
        }
        return value
    }
}

/// The reply to one message, from whichever thread it arrives on.
final class Outcome<Value: Sendable>: Sendable {
    private enum State {
        case waiting
        case replied(Value)
        /// The connection failed before a reply came.
        case failed
        case timedOut
    }

    private let state = Mutex<State>(.waiting)
    private let done = DispatchSemaphore(value: 0)

    /// The reply, or nil when the connection failed. Only the first counts.
    func finish(_ value: Value?) {
        let first = state.withLock { state in
            guard case .waiting = state else { return false }
            state = value.map { .replied($0) } ?? .failed
            return true
        }
        if first { done.signal() }
    }

    /// The reply, or nil if the connection failed or no reply came in time.
    func wait(for timeout: Duration, isPaused: @Sendable () -> Bool = { false }) -> Value? {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        var remaining = seconds
        var previous = ContinuousClock.now
        while true {
            if Task.isCancelled {
                finish(nil)
                return nil
            }
            let slice = isPaused() ? 0.025 : min(0.025, max(0, remaining))
            if done.wait(timeout: .now() + slice) == .success { break }
            let now = ContinuousClock.now
            let elapsed = now - previous
            if !isPaused() {
                remaining -= Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            }
            previous = now
            guard remaining > 0 else {
                state.withLock { state in
                    if case .waiting = state { state = .timedOut }
                }
                break
            }
        }
        return state.withLock { state in
            if case .replied(let value) = state { return value }
            return nil
        }
    }

    var timedOut: Bool {
        state.withLock { state in
            if case .timedOut = state { return true }
            return false
        }
    }
}
