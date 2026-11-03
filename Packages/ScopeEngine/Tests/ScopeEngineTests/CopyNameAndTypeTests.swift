import Foundation
import Testing

@testable import ScopeEngine

/// Copies of names at the disk's length limit, and of folders holding items
/// a copy can't reproduce (#143, #144). Everything is in a temporary folder.
@Suite struct CopyNameAndTypeTests {
    let sandbox: Sandbox
    var engine: FileEngine { sandbox.engine }

    init() throws {
        sandbox = try Sandbox()
    }

    private func partials(in relative: String = "") throws -> [String] {
        try sandbox.names(in: relative).filter { $0.hasPrefix(FileEngine.partialPrefix) }
    }

    // MARK: - Long names (#143)

    @Test(arguments: [
        String(repeating: "a", count: 251) + ".txt",  // 255 bytes, the limit
        String(repeating: "é", count: 125) + ".txt",  // 254 bytes in 129 characters
        String(repeating: "a", count: 220) + ".txt",  // the length from the report
    ])
    func copiesAFileWithALongName(name: String) async throws {
        #expect(storedLength(name) <= FileEngine.maxNameBytes)
        let source = try sandbox.write("source/" + name, "sentinel")
        try sandbox.mkdir("destination")
        try await engine.copyItem(at: source, to: sandbox.url("destination/" + name))
        #expect(try String(contentsOf: sandbox.url("destination/" + name), encoding: .utf8) == "sentinel")
        #expect(try partials(in: "destination") == [])
    }

    @Test func copiesAFolderWithALongNameAndLongChildren() async throws {
        let folder = String(repeating: "f", count: 255)
        let child = String(repeating: "c", count: 255)
        try sandbox.write("source/\(folder)/\(child)", "inside")
        try sandbox.mkdir("destination")
        try await engine.copyItem(at: sandbox.url("source/" + folder), to: sandbox.url("destination/" + folder))
        #expect(try String(contentsOf: sandbox.url("destination/\(folder)/\(child)"), encoding: .utf8) == "inside")
        #expect(try partials(in: "destination") == [])
    }

    /// File URLs may hand names back decomposed, so lengths are compared
    /// as the disk stores them, and each generated name is really created.
    private func storedLength(_ name: String) -> Int {
        name.precomposedStringWithCanonicalMapping.utf8.count
    }

    @Test func generatedNamesStayWithinTheLimit() throws {
        let base = String(repeating: "é", count: 125)
        let name = base + ".txt"
        try sandbox.write(name, "original")
        let copy = try engine.uniqueName(name, in: sandbox.root, style: .copy)
        #expect(storedLength(copy.lastPathComponent) <= FileEngine.maxNameBytes)
        #expect(copy.lastPathComponent.hasSuffix(" copy.txt") && copy.lastPathComponent.hasPrefix("éé"))
        try Data("copy".utf8).write(to: copy)
        let second = try engine.uniqueName(name, in: sandbox.root, style: .copy)
        #expect(storedLength(second.lastPathComponent) <= FileEngine.maxNameBytes)
        #expect(second.lastPathComponent.hasSuffix(" copy 2.txt"))
        try Data("second".utf8).write(to: second)
        let numbered = try engine.uniqueName(name, in: sandbox.root, style: .numbered)
        #expect(storedLength(numbered.lastPathComponent) <= FileEngine.maxNameBytes)
        #expect(numbered.lastPathComponent.hasSuffix(" 2.txt"))
        try Data("numbered".utf8).write(to: numbered)
        #expect(try sandbox.names().count == 4)
        // Short names are untouched.
        #expect(FileEngine.fittingName("photo", " copy.jpg") == "photo copy.jpg")
    }

    @Test func duplicatesAFileWhoseNameIsAtTheLimit() async throws {
        let name = String(repeating: "a", count: 251) + ".txt"
        try sandbox.write(name, "original")
        try await OperationHarness(engine: engine).run(.duplicate([sandbox.url(name)]))
        let names = try sandbox.names()
        #expect(names.count == 2)
        let copy = try #require(names.first { $0 != name })
        #expect(copy.hasSuffix(" copy.txt") && storedLength(copy) <= FileEngine.maxNameBytes)
        #expect(try String(contentsOf: sandbox.url(copy), encoding: .utf8) == "original")
    }

    // MARK: - Items a copy can't reproduce (#144)

    /// Never opened: a FIFO with no writer would block a read.
    private func makeFIFO(_ relative: String) throws {
        try FileManager.default.createDirectory(
            at: sandbox.url(relative).deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(mkfifo(sandbox.url(relative).path, 0o600) == 0)
    }

    @Test func aFolderHoldingANamedPipeFailsInsteadOfCopyingWithoutIt() async throws {
        try sandbox.write("source/note.txt", "sentinel")
        try makeFIFO("source/nested/pipe")
        try sandbox.mkdir("destination")
        let before = try TreeSnapshot(sandbox.url("source"))
        let pipe = sandbox.url("source/nested/pipe").path
        let refusal = FileEngineError.unsupportedItem(pipe, kind: "a named pipe (FIFO)")
        await #expect(throws: refusal) {
            try await engine.copyItem(at: sandbox.url("source"), to: sandbox.url("destination/source"))
        }
        #expect(try sandbox.names(in: "destination") == [])
        #expect(try TreeSnapshot(sandbox.url("source")) == before)
    }

    @Test func aNamedPipeOnItsOwnIsRefused() async throws {
        try makeFIFO("pipe")
        try sandbox.mkdir("destination")
        await #expect(throws: FileEngineError.self) {
            try await engine.copyItem(at: sandbox.url("pipe"), to: sandbox.url("destination/pipe"))
        }
        #expect(try sandbox.names(in: "destination") == [])
        #expect(sandbox.exists("pipe"))
    }

    @Test func aCopyOperationStopsAtAPipeInsteadOfReportingSuccess() async throws {
        try sandbox.write("source/note.txt", "sentinel")
        try makeFIFO("source/pipe")
        try sandbox.mkdir("destination")
        await #expect(throws: FileEngineError.self) {
            try await OperationHarness(engine: engine).run(
                .copy([sandbox.url("source")], into: sandbox.url("destination")))
        }
        #expect(try sandbox.names(in: "destination") == [])
        #expect(sandbox.exists("source/pipe") && sandbox.exists("source/note.txt"))
    }

    @Test func onlyFoldersFilesAndLinksAreCopyable() throws {
        // copy() checks each item again as it reaches it, so a regular file
        // replaced by a FIFO between measuring and copying is never opened.
        try makeFIFO("source/pipe")
        let info = try #require(FileEngine.lstatInfo(sandbox.url("source/pipe").path))
        #expect(throws: FileEngineError.self) { try CopyJob.checkCopyable(info, path: "pipe") }
        let file = try sandbox.write("file.txt", "x")
        let regular = try #require(FileEngine.lstatInfo(file.path))
        try CopyJob.checkCopyable(regular, path: "file.txt")
    }

    @Test func refusalsAreNotOfferedARetry() {
        #expect(!FailurePolicy.isRetryable(FileEngineError.unsupportedItem("/x", kind: "a socket")))
    }
}
