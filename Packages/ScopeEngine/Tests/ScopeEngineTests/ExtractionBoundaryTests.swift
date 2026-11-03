import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

/// Extraction writes only through the pinned staging folder (#145) and holds
/// a bounded amount of metadata (#149). Both the allowed folder and every
/// "outside" folder are fresh temporary fixtures owned by the test.
@Suite(.serialized) struct ExtractionBoundaryTests {
    // MARK: - Replaced staging and folders (#145)

    @Test func aReplacedStagingFolderCannotRedirectWrites() async throws {
        let sandbox = try Sandbox()
        let outside = try Sandbox()
        let archive = try sandbox.write("input.bin", "fixture")
        let before = try TreeSnapshot(outside.root)
        var engine = sandbox.engine
        engine.archiveReaders = SwappingReaders(
            entries: [(ArchiveEntry(name: "escaped.txt", kind: .file, size: 7), "payload")],
            swap: { [root = sandbox.root, target = outside.root] in try swapStaging(in: root, for: target) })
        _ = try? await OperationHarness(engine: engine).run(.extract(archive))
        #expect(try TreeSnapshot(outside.root) == before)
        #expect(!outside.exists("escaped.txt"))
        // The entry went into the real staging folder, wherever it was moved
        // inside the allowed folder, and at most from there into place.
        #expect(sandbox.exists("escaped.txt") || sandbox.exists("saved-staging/escaped.txt"))
        try removeLinks(in: sandbox.root)
    }

    @Test func aFolderReplacedByALinkMidwayIsNotWrittenThrough() async throws {
        let sandbox = try Sandbox()
        let outside = try Sandbox()
        let archive = try sandbox.write("input.bin", "fixture")
        let before = try TreeSnapshot(outside.root)
        var engine = sandbox.engine
        // After "sub/a.txt" is written, "sub" in staging becomes a link to
        // the outside folder, before "sub/b.txt" arrives.
        engine.archiveReaders = SwappingReaders(
            entries: [
                (ArchiveEntry(name: "sub/a.txt", kind: .file), "first"),
                (ArchiveEntry(name: "sub/b.txt", kind: .file), "second"),
                (ArchiveEntry(name: "other.txt", kind: .file), "third"),
            ],
            swapBefore: 1,
            swap: { [root = sandbox.root, target = outside.root] in
                let staging = try stagingFolder(in: root)
                let sub = staging.appendingPathComponent("sub")
                try FileManager.default.moveItem(at: sub, to: staging.appendingPathComponent("saved-sub"))
                try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: target)
            })
        let control = OperationControl()
        _ = try? await OperationHarness(engine: engine).run(.extract(archive), control: control)
        #expect(try TreeSnapshot(outside.root) == before)
        #expect(!outside.exists("b.txt"))
        try removeLinks(in: sandbox.root)
    }

    @Test func aMovedArchiveFolderIsNotPublishedInto() async throws {
        let sandbox = try Sandbox()
        let outside = try Sandbox()
        let archive = try sandbox.write("work/input.bin", "fixture")
        let before = try TreeSnapshot(outside.root)
        var engine = sandbox.engine
        // The archive's folder is moved aside and its name pointed outside.
        engine.archiveReaders = SwappingReaders(
            entries: [(ArchiveEntry(name: "result.txt", kind: .file), "payload")],
            swap: { [root = sandbox.root, target = outside.root] in
                let work = root.appendingPathComponent("work")
                try FileManager.default.moveItem(at: work, to: root.appendingPathComponent("moved"))
                try FileManager.default.createSymbolicLink(at: work, withDestinationURL: target)
            })
        await #expect(throws: (any Error).self) { try await OperationHarness(engine: engine).run(.extract(archive)) }
        #expect(try TreeSnapshot(outside.root) == before)
        // The staging folder moved with its folder and was removed there.
        #expect(try sandbox.names(in: "moved") == ["input.bin"])
        try removeLinks(in: sandbox.root)
    }

    @Test func extractionStillPublishesNormally() async throws {
        let sandbox = try Sandbox()
        let archive = try sandbox.write("input.bin", "fixture")
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(entries: [
            (ArchiveEntry(name: "folder/", kind: .directory, permissions: 0o750), nil),
            (ArchiveEntry(name: "folder/deep/note.txt", kind: .file, permissions: 0o444), "note"),
            (ArchiveEntry(name: "folder/link", kind: .symlink(to: "deep/note.txt")), nil),
            (ArchiveEntry(name: "folder/again.txt", kind: .hardlink(to: "folder/deep/note.txt")), nil),
        ])
        let control = OperationControl()
        try await OperationHarness(engine: engine).run(.extract(archive), control: control)
        #expect(control.skippedEntries.isEmpty)
        #expect(try String(contentsOf: sandbox.url("folder/deep/note.txt"), encoding: .utf8) == "note")
        #expect(FileEngine.lstatInfo(sandbox.url("folder").path).map { $0.st_mode & 0o777 } == 0o750)
        #expect(FileEngine.lstatInfo(sandbox.url("folder/deep/note.txt").path).map { $0.st_mode & 0o777 } == 0o444)
        #expect(FileEngine.isSameItem(sandbox.url("folder/again.txt").path, sandbox.url("folder/deep/note.txt").path))
        #expect(try sandbox.names().allSatisfy { !$0.hasPrefix(FileEngine.partialPrefix) })
    }

    // MARK: - Metadata held in memory (#149)

    @Test func repeatedSidecarsAreAppliedAndReleased() async throws {
        let sandbox = try Sandbox()
        let input = try sandbox.write("input.bin", "fixture")
        let observed = Recorded<Int>()
        var engine = sandbox.engine
        engine.archiveReaders = MetadataReaders(observed: observed, sidecars: 24, size: 1024 * 1024)
        try await OperationHarness(engine: engine).run(.extract(input))
        // Each 1 MiB sidecar is written as it arrives, then dropped; at most
        // the one being applied (and the reader's) is alive at the end.
        #expect(observed.all.allSatisfy { $0 <= 2 * 1024 * 1024 })
        #expect(getxattr(sandbox.url("file").path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW) == 1024 * 1024)
    }

    @Test func sidecarsBeforeTheirFileAreAppliedWhenItArrives() async throws {
        let sandbox = try Sandbox()
        let archive = try sandbox.write("input.bin", "fixture")
        var early = ArchiveEntry(name: "note.txt", kind: .metadata)
        early.extendedAttributes = ["user.first": Data("early".utf8), "user.shared": Data("old".utf8)]
        var later = ArchiveEntry(name: "note.txt", kind: .metadata)
        later.extendedAttributes = ["user.shared": Data("new".utf8)]
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(entries: [
            (early, nil), (later, nil), (ArchiveEntry(name: "note.txt", kind: .file, permissions: 0o444), "text"),
        ])
        try await OperationHarness(engine: engine).run(.extract(archive))
        #expect(xattr(sandbox.url("note.txt"), "user.first") == "early")
        #expect(xattr(sandbox.url("note.txt"), "user.shared") == "new")
        #expect(FileEngine.lstatInfo(sandbox.url("note.txt").path).map { $0.st_mode & 0o777 } == 0o444)
    }

    @Test func pendingMetadataBeyondTheBudgetStopsAndKeepsNothing() async throws {
        let sandbox = try Sandbox()
        let archive = try sandbox.write("input.bin", "fixture")
        var entries: [(ArchiveEntry, String?)] = []
        for index in 0..<8 {
            var sidecar = ArchiveEntry(name: "file-\(index)", kind: .metadata)
            sidecar.extendedAttributes = ["user.blob": Data(count: 1024)]
            entries.append((sidecar, nil))
        }
        entries.append((ArchiveEntry(name: "file-0", kind: .file), "data"))
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(entries: entries)
        engine.extractionLimits.pendingMetadataBytes = 4 * 1024
        await #expect(throws: OperationError.self) { try await OperationHarness(engine: engine).run(.extract(archive)) }
        #expect(try sandbox.names() == ["input.bin"])
    }

    @Test func sidecarsForAFileThatNeverArrivesAreRefused() async throws {
        let sandbox = try Sandbox()
        let archive = try sandbox.write("input.bin", "fixture")
        var orphan = ArchiveEntry(name: "missing.txt", kind: .metadata)
        orphan.extendedAttributes = ["user.test": Data("value".utf8)]
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(entries: [
            (orphan, nil), (ArchiveEntry(name: "present.txt", kind: .file), "text"),
        ])
        await #expect(throws: OperationError.self) { try await OperationHarness(engine: engine).run(.extract(archive)) }
        #expect(try sandbox.names() == ["input.bin"])
    }

    @Test func sidecarsForAnImplicitFolderAreAppliedAtTheEnd() async throws {
        let sandbox = try Sandbox()
        let archive = try sandbox.write("input.bin", "fixture")
        var sidecar = ArchiveEntry(name: "folder", kind: .metadata)
        sidecar.extendedAttributes = ["user.test": Data("folder".utf8)]
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(entries: [
            (sidecar, nil), (ArchiveEntry(name: "folder/note.txt", kind: .file), "text"),
        ])
        try await OperationHarness(engine: engine).run(.extract(archive))
        #expect(xattr(sandbox.url("folder"), "user.test") == "folder")
    }

    @Test func archivesWithMoreEntriesThanTheLimitStopAndKeepNothing() async throws {
        let sandbox = try Sandbox()
        let archive = try sandbox.write("input.bin", "fixture")
        var engine = sandbox.engine
        engine.archiveReaders = FakeReaders(entries: (0..<4).map { (ArchiveEntry(name: "f\($0)", kind: .file), "x") })
        engine.extractionLimits.entries = 3
        await #expect(throws: OperationError.self) { try await OperationHarness(engine: engine).run(.extract(archive)) }
        #expect(try sandbox.names() == ["input.bin"])
    }

    private func xattr(_ url: URL, _ name: String) -> String? {
        let length = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length >= 0 else { return nil }
        var data = Data(count: length)
        _ = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
        return String(bytes: data, encoding: .utf8)
    }
}

// MARK: - Fixtures

/// Unlinks the links a test swapped in (never following them), so cleanup
/// of the allowed folder can't reach the outside fixture through one.
private func removeLinks(in folder: URL) throws {
    guard let enumerator = FileManager.default.enumerator(atPath: folder.path) else { return }
    var links: [String] = []
    for case let relative as String in enumerator {
        let path = folder.path + "/" + relative
        if FileEngine.lstatInfo(path).map({ $0.st_mode & S_IFMT == S_IFLNK }) == true { links.append(path) }
    }
    for path in links { #expect(unlink(path) == 0) }
}

/// The extraction's staging folder in `folder`, found by its prefix.
private func stagingFolder(in folder: URL) throws -> URL {
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    guard let name = names.first(where: { $0.hasPrefix(FileEngine.partialPrefix) }) else {
        throw ArchiveReadError.damaged("Missing fixture staging")
    }
    return folder.appendingPathComponent(name)
}

/// Moves the staging folder aside and puts a link to `outside` in its place.
private func swapStaging(in folder: URL, for outside: URL) throws {
    let staging = try stagingFolder(in: folder)
    try FileManager.default.moveItem(at: staging, to: folder.appendingPathComponent("saved-staging"))
    try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: outside)
}

/// Entries in order; `swap` runs once, just before entry `swapBefore` is returned.
private struct SwappingReaders: ArchiveReaderOpening {
    let entries: [(ArchiveEntry, String?)]
    var swapBefore = 0
    let swap: @Sendable () throws -> Void

    func open(_ archive: FileHandle, singleFile: Bool) throws(ArchiveReadError) -> any ArchiveReading {
        SwappingReader(entries: entries, swapBefore: swapBefore, swap: swap)
    }
}

private final class SwappingReader: ArchiveReading {
    private var remaining: [(ArchiveEntry, String?)]
    private var data = Data()
    private var index = 0
    private let swapBefore: Int
    private let swap: @Sendable () throws -> Void

    init(entries: [(ArchiveEntry, String?)], swapBefore: Int, swap: @escaping @Sendable () throws -> Void) {
        remaining = entries
        self.swapBefore = swapBefore
        self.swap = swap
    }

    func nextEntry() throws(ArchiveReadError) -> ArchiveEntry? {
        if index == swapBefore {
            do { try swap() } catch { throw .damaged(error.localizedDescription) }
        }
        index += 1
        guard !remaining.isEmpty else { return nil }
        let (entry, contents) = remaining.removeFirst()
        data = Data((contents ?? "").utf8)
        return entry
    }

    func readData(upTo limit: Int) throws(ArchiveReadError) -> Data {
        let chunk = data.prefix(limit)
        data = data.dropFirst(chunk.count)
        return Data(chunk)
    }
}

/// An empty file followed by `sidecars` metadata entries for it, each owning
/// its own allocation. Records how many payload bytes are still alive at EOF.
private struct MetadataReaders: ArchiveReaderOpening {
    let observed: Recorded<Int>
    let sidecars: Int
    let size: Int

    func open(_ archive: FileHandle, singleFile: Bool) throws(ArchiveReadError) -> any ArchiveReading {
        MetadataReader(observed: observed, sidecars: sidecars, size: size)
    }
}

private final class LiveBytes: Sendable {
    let value = Mutex<Int>(0)
}

private final class MetadataReader: ArchiveReading {
    let observed: Recorded<Int>
    let sidecars: Int
    let size: Int
    let live = LiveBytes()
    var index = 0

    init(observed: Recorded<Int>, sidecars: Int, size: Int) {
        self.observed = observed
        self.sidecars = sidecars
        self.size = size
    }

    func nextEntry() throws(ArchiveReadError) -> ArchiveEntry? {
        if index == 0 {
            index += 1
            return ArchiveEntry(name: "file", kind: .file, size: 0)
        }
        guard index <= sidecars else {
            observed.append(live.value.withLock { $0 })
            return nil
        }
        index += 1
        let size = size
        let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        memory.initializeMemory(as: UInt8.self, repeating: UInt8(truncatingIfNeeded: index), count: size)
        let live = live
        live.value.withLock { $0 += size }
        let data = Data(
            bytesNoCopy: memory, count: size,
            deallocator: .custom { pointer, count in
                pointer.deallocate()
                live.value.withLock { $0 -= count }
            })
        var entry = ArchiveEntry(name: "file", kind: .metadata, size: Int64(size))
        entry.extendedAttributes = ["com.apple.ResourceFork": data]
        return entry
    }

    func readData(upTo limit: Int) throws(ArchiveReadError) -> Data { Data() }
}
