import Foundation
import Testing

@testable import ScopeEngine

/// Reading archives over XPC, as the app does with its sandboxed archive
/// service. Here the service runs in the test process behind an anonymous
/// listener, which goes through the same encoding and file handle passing.
struct ArchiveServiceTests {
    let sandbox: Sandbox

    init() throws {
        sandbox = try Sandbox()
    }

    @Test func extractsThroughTheService() async throws {
        let service = ServiceHarness(ArchiveServiceListener())
        var engine = sandbox.engine
        engine.archiveReaders = service.readers()
        let tar = TarBuilder()
            .file("project/readme.txt", "hello")
            .file("project/src/main.swift", "print(1)")
            .symlink("project/link", to: "readme.txt")
            .data()
        try sandbox.write("project.tar", tar)
        try await OperationHarness(engine: engine).run(.extract(sandbox.url("project.tar")))

        #expect(try text("project/readme.txt") == "hello")
        #expect(try text("project/src/main.swift") == "print(1)")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: sandbox.url("project/link").path)
                == "readme.txt")
        #expect(engine.declaredUnpackedSize(sandbox.url("project.tar")) == 13)
    }

    @Test func bigEntriesArriveInChunks() async throws {
        let service = ServiceHarness(ArchiveServiceListener())
        var engine = sandbox.engine
        engine.archiveReaders = service.readers()
        let big = String(repeating: "0123456789abcdef", count: 600_000)  // 9.6 MB, three chunks
        try sandbox.write("big.tar", TarBuilder().file("big.txt", big).data())
        try await OperationHarness(engine: engine).run(.extract(sandbox.url("big.tar")))
        #expect(try text("big.txt") == big)
    }

    @Test func namesFromTheServiceAreStillChecked() async throws {
        let service = ServiceHarness(
            ArchiveServiceListener(
                readers: FakeReaders(entries: [
                    (ArchiveEntry(name: "../escaped.txt", kind: .file), "escape"),
                    (ArchiveEntry(name: "out", kind: .symlink(to: "/etc")), nil),
                    (ArchiveEntry(name: "out/scope-test.txt", kind: .file), "through the link"),
                    (ArchiveEntry(name: "innocent.txt", kind: .file), "fine"),
                ])))
        var engine = sandbox.engine
        engine.archiveReaders = service.readers()
        try sandbox.write("evil.zip", "not read")
        let control = OperationControl()
        try await OperationHarness(engine: engine).run(.extract(sandbox.url("evil.zip")), control: control)

        #expect(control.skippedEntries.count == 2)
        #expect(try sandbox.names(in: "evil") == ["innocent.txt", "out"])
        #expect(!FileManager.default.fileExists(atPath: "/etc/scope-test.txt"))
    }

    @Test func aFileThatIsntAnArchiveIsReportedAsSuch() async throws {
        let service = ServiceHarness(ArchiveServiceListener())
        var engine = sandbox.engine
        engine.archiveReaders = service.readers()
        try sandbox.write("plain.tar", "just text")
        await #expect(throws: (any Error).self) {
            try await OperationHarness(engine: engine).run(.extract(self.sandbox.url("plain.tar")))
        }
        #expect(try sandbox.names() == ["plain.tar"])
    }

    @Test(arguments: [RogueService.Fault.garbledEntry, .oversizedChunk, .silence])
    func aMisbehavingServiceStopsTheExtraction(_ fault: RogueService.Fault) async throws {
        let service = ServiceHarness(RogueListener(fault: fault))
        var engine = sandbox.engine
        engine.archiveReaders = service.readers(timeout: .milliseconds(300))
        try sandbox.write("rogue.zip", "not read")
        await #expect(throws: OperationError.self) {
            try await OperationHarness(engine: engine).run(.extract(self.sandbox.url("rogue.zip")))
        }
        #expect(try sandbox.names() == ["rogue.zip"])
    }

    private func text(_ relative: String) throws -> String {
        try String(contentsOf: sandbox.url(relative), encoding: .utf8)
    }
}

/// An anonymous listener in the test process standing in for the service.
final class ServiceHarness: @unchecked Sendable {
    private let listener = NSXPCListener.anonymous()
    /// The listener holds its delegate weakly.
    private let acceptor: any NSXPCListenerDelegate

    init(_ acceptor: any NSXPCListenerDelegate) {
        self.acceptor = acceptor
        listener.delegate = acceptor
        listener.resume()
    }

    deinit {
        listener.invalidate()
    }

    func readers(timeout: Duration = .seconds(60)) -> XPCArchiveReaders {
        XPCArchiveReaders(timeout: timeout) { [self] in NSXPCConnection(listenerEndpoint: listener.endpoint) }
    }

    func writers(timeout: Duration = .seconds(60)) -> XPCArchiveWriters {
        XPCArchiveWriters(timeout: timeout) { [self] in NSXPCConnection(listenerEndpoint: listener.endpoint) }
    }
}

final class RogueListener: NSObject, NSXPCListenerDelegate, Sendable {
    let fault: RogueService.Fault

    init(fault: RogueService.Fault) {
        self.fault = fault
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = ArchiveService.interface
        connection.exportedObject = RogueService(fault: fault)
        connection.resume()
        return true
    }
}

/// A service that has gone wrong, as a compromised one might.
final class RogueService: NSObject, ArchiveServiceProtocol, Sendable {
    enum Fault: Sendable, CaseIterable {
        /// Replies to "next entry" with something that doesn't decode.
        case garbledEntry
        /// Sends more data than was asked for.
        case oversizedChunk
        /// Never replies to "next entry".
        case silence
    }

    let fault: Fault

    init(fault: Fault) {
        self.fault = fault
    }

    func open(_ archive: FileHandle, singleFile: Bool, reply: @escaping @Sendable (Data?) -> Void) {
        reply(nil)
    }

    func nextEntry(reply: @escaping @Sendable (Data) -> Void) {
        switch fault {
        case .garbledEntry:
            reply(Data("{\"not\": \"an entry\"}".utf8))
        case .oversizedChunk:
            let entry = ServiceReply<ArchiveEntry?>.success(ArchiveEntry(name: "a.txt", kind: .file))
            reply((try? JSONEncoder().encode(entry)) ?? Data())
        case .silence:
            break
        }
    }

    func readData(upTo limit: Int, reply: @escaping @Sendable (Data?, Data?) -> Void) {
        reply(Data(count: limit + 1), nil)
    }
}
