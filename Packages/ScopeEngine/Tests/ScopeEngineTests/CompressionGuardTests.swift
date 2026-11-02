import Foundation
import Testing

@testable import ScopeEngine

struct CompressionGuardTests {
    @Test func swappingTheDestinationParentCannotRedirectAnArchive() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("allowed/folder/input.txt", "inside")
        try sandbox.write("outside/sentinel", "untouched")
        let folder = sandbox.url("allowed/folder")
        let saved = sandbox.url("allowed/saved")
        let outside = sandbox.url("outside")
        let before = try TreeSnapshot(outside)
        var engine = FileEngine(pathGuard: .writesOnlyUnder([sandbox.url("allowed")]))
        engine.archiveWriters = HookedWriters(beforeOpen: {
            try FileManager.default.moveItem(at: folder, to: saved)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        })
        await #expect(throws: (any Error).self) {
            try await OperationHarness(engine: engine).run(.compress([source], format: .zip))
        }
        #expect(try TreeSnapshot(outside) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: saved.path) == ["input.txt"])
    }

    @Test func anOpenedSourceCannotBeRedirectedToAnOutsideFile() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("allowed/original/child.txt", "inside")
        try sandbox.write("outside/sentinel", "outside")
        let saved = sandbox.url("allowed/saved.txt")
        let outside = sandbox.url("outside/sentinel")
        var engine = FileEngine(pathGuard: .restricted(to: [sandbox.url("allowed")]))
        engine.archiveWriters = HookedWriters(beforeEntry: { entry in
            guard entry.name == "original/child.txt" else { return }
            try FileManager.default.moveItem(at: source, to: saved)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        })
        let ops = OperationHarness(engine: engine)
        try await ops.run(.compress([sandbox.url("allowed/original")], format: .zip))
        try await ops.run(.extract(sandbox.url("allowed/original.zip")))
        #expect(try String(contentsOf: sandbox.url("allowed/original 2/child.txt"), encoding: .utf8) == "inside")
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
    }

    @Test func aSourceThatShrinksIsRefused() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("input.txt", "original data")
        var engine = sandbox.engine
        engine.archiveWriters = HookedWriters(beforeEntry: { entry in
            guard entry.name == "input.txt" else { return }
            let file = try FileHandle(forWritingTo: source)
            try file.truncate(atOffset: 0)
            try file.close()
        })
        await #expect(throws: OperationError.self) {
            try await OperationHarness(engine: engine).run(.compress([source], format: .zip))
        }
        #expect(try sandbox.names() == ["input.txt"])
    }
}

private struct HookedWriters: ArchiveWriterOpening {
    var beforeOpen: @Sendable () throws -> Void = {}
    var beforeEntry: @Sendable (ArchiveEntry) throws -> Void = { _ in }

    func open(
        format: ArchiveFormat, control: OperationControl?, output: @escaping ArchiveDataSink
    )
        throws(ArchiveWriteError) -> any ArchiveWriting
    {
        do { try beforeOpen() } catch { throw .failed(error.localizedDescription) }
        return try HookedWriter(
            base: LibArchiveWriters().open(format: format, control: control, output: output), hook: beforeEntry)
    }
}

private final class HookedWriter: ArchiveWriting {
    let base: any ArchiveWriting
    let hook: @Sendable (ArchiveEntry) throws -> Void

    init(base: any ArchiveWriting, hook: @escaping @Sendable (ArchiveEntry) throws -> Void) {
        self.base = base
        self.hook = hook
    }

    func beginEntry(_ entry: ArchiveEntry) throws(ArchiveWriteError) {
        do { try hook(entry) } catch { throw .failed(error.localizedDescription) }
        try base.beginEntry(entry)
    }
    func writeData(_ data: Data) throws(ArchiveWriteError) { try base.writeData(data) }
    func finishEntry() throws(ArchiveWriteError) { try base.finishEntry() }
    func finish() throws(ArchiveWriteError) { try base.finish() }
    func cancel() { base.cancel() }
}
