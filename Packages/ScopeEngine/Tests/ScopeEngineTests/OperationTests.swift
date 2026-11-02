import Foundation
import Testing

@testable import ScopeEngine

/// Operations on real mounted volumes: copy, move (on one disk and between
/// two), conflicts, Trash, undo, cancel, archives. Each test gets fresh disks.
@Suite(.serialized) struct OperationTests {
    let disk: TestVolume
    let other: TestVolume
    let engine: FileEngine
    var ops: OperationHarness

    init() throws {
        disk = try TestVolume(name: "ScopeOpsA")
        other = try TestVolume(name: "ScopeOpsB")
        engine = FileEngine(pathGuard: .restricted(to: [disk.mountPoint, other.mountPoint]))
        ops = OperationHarness(engine: engine)
    }

    // MARK: - Copy

    @Test func copiesIntoAFolderAndUndoes() async throws {
        try disk.write("a.txt", "a")
        try disk.write("folder/b.txt", "b")
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)

        let record = try await ops.run(.copy([disk.url("a.txt"), disk.url("folder")], into: disk.url("dest")))
        #expect(try disk.names("dest") == ["a.txt", "folder"])
        #expect(try disk.read("dest/folder/b.txt") == "b")

        try await ops.undo(record)
        #expect(try disk.names("dest") == [])
        #expect(try disk.read("a.txt") == "a")
    }

    @Test func pastingIntoTheSameFolderMakesACopy() async throws {
        try disk.write("photo.jpg", "x")
        try await ops.run(.copy([disk.url("photo.jpg")], into: disk.work))
        try await ops.run(.copy([disk.url("photo.jpg")], into: disk.work))
        #expect(try disk.names() == ["photo copy 2.jpg", "photo copy.jpg", "photo.jpg"])
    }

    @Test func conflictKeepBothSkipAndStop() async throws {
        try disk.write("src/a.txt", "new")
        try disk.write("dest/a.txt", "old")
        var harness = ops

        harness.conflictAnswer = .keepBoth
        try await harness.run(.copy([disk.url("src/a.txt")], into: disk.url("dest")))
        #expect(try disk.names("dest") == ["a 2.txt", "a.txt"])

        harness.conflictAnswer = .skip
        try await harness.run(.copy([disk.url("src/a.txt")], into: disk.url("dest")))
        #expect(try disk.read("dest/a.txt") == "old")

        harness.conflictAnswer = .stop
        await #expect(throws: OperationError.stoppedByUser) {
            try await harness.run(.copy([disk.url("src/a.txt")], into: disk.url("dest")))
        }
        #expect(try disk.read("dest/a.txt") == "old")
    }

    @Test func replaceTrashesTheOldItemAndUndoBringsItBack() async throws {
        try disk.write("src/a.txt", "new")
        try disk.write("dest/a.txt", "old")
        var harness = ops
        harness.conflictAnswer = .replace

        let record = try await harness.run(.copy([disk.url("src/a.txt")], into: disk.url("dest")))
        #expect(try disk.read("dest/a.txt") == "new")
        // The old one went to this disk's Trash, not away.
        let trashed = record.steps.compactMap { step -> URL? in
            if case .putBack(let trashed, _) = step { return trashed }
            return nil
        }
        #expect(trashed.count == 1 && trashed[0].path.hasPrefix(disk.mountPoint.path))

        try await harness.undo(record)
        #expect(try disk.read("dest/a.txt") == "old")
    }

    @Test func replaceKeepsTheExistingItemWhenTheCopyFails() async throws {
        try disk.write("src/a/readable.txt", "new")
        let unreadable = try disk.write("src/a/unreadable.txt", "new")
        try disk.write("dest/a/old.txt", "old")
        chmod(unreadable.path, 0)
        defer { chmod(unreadable.path, 0o644) }
        var harness = ops
        harness.conflictAnswer = .replace

        await #expect(throws: (any Error).self) {
            try await harness.run(.copy([disk.url("src/a")], into: disk.url("dest")))
        }
        // The copy failed, so the existing folder was never trashed, and no
        // partial copy is left next to it.
        #expect(try disk.read("dest/a/old.txt") == "old")
        #expect(try disk.names("dest") == ["a"])
    }

    @Test func cancellingWhileAConflictIsOpenKeepsTheExistingItem() async throws {
        try disk.write("src/a.txt", "new")
        try disk.write("dest/a.txt", "old")
        let engine = engine
        let source = disk.url("src/a.txt")
        let folder = disk.url("dest")

        let task = Task {
            try await engine.run(
                FileOperation(.copy([source], into: folder)), control: OperationControl(), undo: UndoRecorder()
            ) { _ in
                // The user cancels while the question is open, then answers Replace.
                withUnsafeCurrentTask { $0?.cancel() }
                return (.replace, false)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try disk.read("dest/a.txt") == "old")
        #expect(try disk.names("dest") == ["a.txt"])
    }

    @Test func replaceDuringAMoveBetweenDisksTrashesTheOldItemLast() async throws {
        try disk.write("a.txt", "new")
        try other.write("a.txt", "old")
        var harness = ops
        harness.conflictAnswer = .replace

        let record = try await harness.run(.move([disk.url("a.txt")], into: other.work))
        #expect(!disk.exists("a.txt"))
        #expect(try other.read("a.txt") == "new")

        try await harness.undo(record)
        #expect(try disk.read("a.txt") == "new")
        #expect(try other.read("a.txt") == "old")
    }

    @Test func aVolumeRootCanNotBeTrashedRenamedOrMoved() async throws {
        // Only a test disk's own root, so a failure here can't reach real files.
        await #expect(throws: PathGuardViolation.self) { try await engine.trashItem(at: disk.mountPoint) }
        await #expect(throws: PathGuardViolation.self) { try await engine.rename(disk.mountPoint, to: "Renamed") }
        await #expect(throws: PathGuardViolation.self) {
            try await engine.moveItem(at: disk.mountPoint, to: other.url("moved"))
        }
        #expect(FileManager.default.fileExists(atPath: disk.work.path))
    }

    @Test func aCancelledCopyOfFilesWithADenyDeleteACLLeavesNothingBehind() async throws {
        let protected = try disk.write("src/a.txt", "a")
        try disk.write("src/z.bin", Data(count: 64 * 1024 * 1024))
        try TestVolume.run("/bin/chmod", ["+a", "everyone deny delete", protected.path])
        // Onto the other disk: a copy within one disk is a clone, done before it can be cancelled.
        try FileManager.default.createDirectory(at: other.url("dest"), withIntermediateDirectories: true)
        let engine = engine
        let source = disk.url("src")
        let target = other.url("dest/src")

        let task = Task {
            try engine.copyItem(
                at: source, to: target, control: nil,
                progress: { progress in
                    // Cancel once a.txt (with its ACL) is in the partial copy.
                    if progress.currentItem == "z.bin" && progress.bytesDone > 0 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try other.names("dest") == [])
    }

    @Test func aFinishedCopyKeepsTheACL() async throws {
        let protected = try disk.write("src/a.txt", "a")
        try TestVolume.run("/bin/chmod", ["+a", "everyone deny delete", protected.path])
        try await ops.run(.copy([disk.url("src")], into: other.work))
        #expect(FileEngine.hasACL(other.url("src/a.txt").path))
    }

    // MARK: - Move

    @Test func movesOnOneDiskAndUndoes() async throws {
        try disk.write("a.txt", "a")
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let record = try await ops.run(.move([disk.url("a.txt")], into: disk.url("dest")))
        #expect(!disk.exists("a.txt") && disk.exists("dest/a.txt"))
        try await ops.undo(record)
        #expect(disk.exists("a.txt") && !disk.exists("dest/a.txt"))
    }

    @Test func movesBetweenDisksByCopyingVerifyingAndTrashing() async throws {
        try disk.write("tree/a.txt", "a")
        try disk.write("tree/sub/b.bin", Data((0..<50_000).map { UInt8($0 % 253) }))
        let before = try TreeSnapshot(disk.url("tree"))

        let record = try await ops.run(.move([disk.url("tree")], into: other.work))
        #expect(!disk.exists("tree"))
        #expect(try TreeSnapshot(other.url("tree")) == before)

        // Undo puts the original back from its disk's Trash and trashes the copy.
        try await ops.undo(record)
        #expect(try TreeSnapshot(disk.url("tree")) == before)
        #expect(!other.exists("tree"))
    }

    @Test func cancellingAMoveBetweenDisksLeavesTheSourceUntouched() async throws {
        try disk.write("big/one.bin", Data(count: 24 * 1024 * 1024))
        let before = try TreeSnapshot(disk.url("big"))
        let control = OperationControl()
        let engine = engine
        let source = disk.url("big")
        let destination = other.work
        let task = Task {
            let undo = UndoRecorder()
            try await engine.run(FileOperation(.move([source], into: destination)), control: control, undo: undo) { _ in
                (.stop, false)
            }
        }
        // Pausing as soon as data flows holds the move mid-copy, however fast the disk.
        while control.progress.bytesDone == 0 { try await Task.sleep(for: .milliseconds(1)) }
        control.isPaused = true
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(try TreeSnapshot(disk.url("big")) == before)
        #expect(try other.names() == [])
    }

    @Test func aMoveToADiskThatGoesAwayKeepsTheSource() async throws {
        // Big enough that the copy is still running when it gets paused.
        try disk.write("big/one.bin", Data(repeating: 3, count: 200 * 1024 * 1024))
        let before = try TreeSnapshot(disk.url("big"))
        let control = OperationControl()
        let engine = engine
        let source = disk.url("big")
        let destination = other.work
        let task = Task {
            let undo = UndoRecorder()
            try await engine.run(FileOperation(.move([source], into: destination)), control: control, undo: undo) { _ in
                (.stop, false)
            }
        }
        // Held mid-copy, then the destination disk is pulled out from under it.
        let deadline = ContinuousClock.now + .seconds(30)
        while control.progress.bytesDone == 0 {
            try #require(ContinuousClock.now < deadline, "the move never started copying")
            try await Task.sleep(for: .milliseconds(1))
        }
        control.isPaused = true
        try other.detach()
        control.isPaused = false
        await #expect(throws: (any Error).self) { try await task.value }

        #expect(try TreeSnapshot(disk.url("big")) == before)
    }

    @Test func aCopyThatFillsTheDiskLeavesNothingBehind() async throws {
        let small = try TestVolume(name: "ScopeFull", sizeMB: 96)
        try small.write("kept.txt", "kept")
        try disk.write("big.bin", Data(repeating: 1, count: 150 * 1024 * 1024))
        let engine = FileEngine(pathGuard: .restricted(to: [disk.mountPoint, small.mountPoint]))

        await #expect(throws: (any Error).self) {
            try await engine.copyItem(at: disk.url("big.bin"), to: small.url("big.bin"))
        }
        #expect(try small.names() == ["kept.txt"])
        #expect(try small.read("kept.txt") == "kept")
    }

    @Test func conflictsCatchOtherSpellingsOfTheSameName() async throws {
        // On a case-insensitive disk that ignores Unicode forms, these are the same names.
        let composed = "caf\u{E9}.txt"
        let decomposed = "cafe\u{301}.txt"
        try disk.write("dest/\(composed)", "old accent")
        try disk.write("dest/Report.txt", "old case")
        try disk.write("src/\(decomposed)", "new accent")
        try disk.write("src/report.txt", "new case")
        var harness = ops
        harness.conflictAnswer = .keepBoth

        let sources = [disk.url("src/\(decomposed)"), disk.url("src/report.txt")]
        try await harness.run(.copy(sources, into: disk.url("dest")))
        let names = try disk.names("dest").map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        #expect(names.sorted() == ["caf\u{E9} 2.txt", "caf\u{E9}.txt", "report 2.txt", "report.txt"])
        #expect(try disk.read("dest/\(composed)") == "old accent")
        #expect(try disk.read("dest/Report.txt") == "old case")
    }

    @Test func refusesToMoveAFolderIntoItself() async throws {
        try disk.write("folder/sub/a.txt", "a")
        await #expect(throws: FileEngineError.self) {
            try await ops.run(.move([disk.url("folder")], into: disk.url("folder/sub")))
        }
        #expect(try disk.read("folder/sub/a.txt") == "a")
    }

    // MARK: - Other operations

    @Test func duplicatesRenamesCreatesAndTrashesWithUndo() async throws {
        try disk.write("a.txt", "a")
        let initial = try TreeSnapshot(disk.work)

        let duplicated = try await ops.run(.duplicate([disk.url("a.txt")]))
        #expect(disk.exists("a copy.txt"))
        let renamed = try await ops.run(.rename(disk.url("a.txt"), to: "b.txt"))
        let created = try await ops.run(.newFolder(in: disk.work, name: "untitled folder"))
        let trashed = try await ops.run(.trash([disk.url("a copy.txt")]))
        #expect(try disk.names() == ["b.txt", "untitled folder"])

        for record in [trashed, created, renamed, duplicated] { try await ops.undo(record) }
        #expect(try TreeSnapshot(disk.work) == initial)
    }

    @Test func undoRefusesWhenTheItemChangedSince() async throws {
        try disk.write("a.txt", "a")
        try FileManager.default.createDirectory(at: disk.url("dest"), withIntermediateDirectories: true)
        let record = try await ops.run(.copy([disk.url("a.txt")], into: disk.url("dest")))
        // Replace the copy with a different file of the same name.
        try FileManager.default.removeItem(at: disk.url("dest/a.txt"))
        try disk.write("dest/a.txt", "someone else's")
        await #expect(throws: OperationError.self) { try await ops.undo(record) }
        #expect(try disk.read("dest/a.txt") == "someone else's")
    }

    /// Random sequences of copy, move, rename, duplicate, new folder and
    /// trash, undone in reverse, must give back the starting tree exactly.
    @Test(arguments: [1, 2, 3, 4, 5])
    func randomOperationsUndoToTheStartingTree(seed: UInt64) async throws {
        var random = SeededRandom(seed: seed)
        for index in 0..<6 { try disk.write("start/file-\(index).txt", "content \(index)") }
        try FileManager.default.createDirectory(at: disk.url("start/inner"), withIntermediateDirectories: true)
        let initial = try TreeSnapshot(disk.url("start"))
        var records: [UndoRecord] = []

        for step in 0..<12 {
            let items = try FileManager.default.contentsOfDirectory(
                at: disk.url("start"), includingPropertiesForKeys: nil
            )
            .filter { $0.lastPathComponent != "inner" }
            guard let item = items.randomElement(using: &random) else { break }
            let kind: FileOperation.Kind =
                switch random.next() % 6 {
                case 0: .copy([item], into: disk.url("start/inner"))
                case 1: .move([item], into: disk.url("start/inner"))
                case 2: .rename(item, to: "renamed-\(seed)-\(step).txt")
                case 3: .duplicate([item])
                case 4: .newFolder(in: disk.url("start"), name: "folder \(step)")
                default: .trash([item])
                }
            var harness = ops
            harness.conflictAnswer = .keepBoth
            records.append(try await harness.run(kind))
        }
        for record in records.reversed() { try await ops.undo(record) }
        #expect(try TreeSnapshot(disk.url("start")) == initial)
    }

    // MARK: - Archives

    @Test(arguments: ArchiveFormat.allCases)
    func compressesAndExtractsBackToTheSameTree(format: ArchiveFormat) async throws {
        try disk.write("project/readme.txt", "hello")
        try disk.write("project/src/main.swift", "print(1)")
        try disk.write("project/empty.txt", "")
        try FileManager.default.createSymbolicLink(
            atPath: disk.url("project/link").path, withDestinationPath: "readme.txt")
        try FileManager.default.createDirectory(at: disk.url("out"), withIntermediateDirectories: true)

        try await ops.run(.compress([disk.url("project")], format: format))
        let archive = "project.\(format.fileExtension)"
        #expect(disk.exists(archive))
        try await ops.run(.move([disk.url(archive)], into: disk.url("out")))
        try await ops.run(.extract(disk.url("out/\(archive)")))

        #expect(try disk.read("out/project/readme.txt") == "hello")
        #expect(try disk.read("out/project/src/main.swift") == "print(1)")
        #expect(try disk.read("out/project/empty.txt") == "")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: disk.url("out/project/link").path) == "readme.txt"
        )
        // No partial files left behind.
        #expect(try disk.names("out").allSatisfy { !$0.hasPrefix(FileEngine.partialPrefix) })
    }

    @Test func extractRefusesEntriesThatEscape() async throws {
        // A tar with "../../escaped.txt", "/tmp/absolute.txt", and a symlink
        // to /etc followed by a file written through it.
        let tar = TarBuilder()
            .file("../../escaped.txt", "escape")
            .file("/tmp/scope-absolute-\(UUID().uuidString).txt", "absolute")
            .symlink("link-out", to: "/etc")
            .file("link-out/scope-test.txt", "through the link")
            .file("innocent.txt", "fine")
            .data()
        try disk.write("evil.tar", tar)
        let control = OperationControl()
        try await ops.run(.extract(disk.url("evil.tar")), control: control)

        #expect(control.skippedEntries.count == 3)
        #expect(!FileManager.default.fileExists(atPath: "/etc/scope-test.txt"))
        #expect(!disk.exists("../escaped.txt"))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: disk.mountPoint.path).contains("escaped.txt") == false)
        #expect(try disk.read("evil/innocent.txt") == "fine")
    }

    @Test func extractsABareGzipFile() async throws {
        try disk.write("note.txt", "compressed text")
        try TestVolume.run("/usr/bin/gzip", [disk.url("note.txt").path])
        try await ops.run(.extract(disk.url("note.txt.gz")))
        #expect(try disk.read("note.txt") == "compressed text")
    }

    @Test func cancellingAnExtractLeavesNothing() async throws {
        try disk.write("big/data.bin", Data(count: 32 * 1024 * 1024))
        try await ops.run(.compress([disk.url("big")], format: .zip))
        try FileManager.default.createDirectory(at: disk.url("x"), withIntermediateDirectories: true)
        try await ops.run(.move([disk.url("big.zip")], into: disk.url("x")))

        let control = OperationControl()
        let engine = engine
        let archive = disk.url("x/big.zip")
        let task = Task {
            try await engine.run(FileOperation(.extract(archive)), control: control, undo: UndoRecorder()) { _ in
                (.stop, false)
            }
        }
        while control.progress.bytesDone == 0 { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        _ = try? await task.value
        #expect(try disk.names("x") == ["big.zip"])
    }

    /// An archive of `megabytes` of zeros (from a sparse file, so it costs no
    /// space) made on the other disk and copied to this one, which is then
    /// filled until the archive no longer fits.
    private func archiveTooBigForTheDisk(_ format: ArchiveFormat, megabytes: Int) async throws -> URL {
        let source = other.url("zeros/zeros.bin")
        try other.write("zeros/zeros.bin", Data())
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(megabytes) * 1024 * 1024)
        try handle.close()
        try await ops.run(.compress([other.url("zeros")], format: format))
        try FileManager.default.createDirectory(at: disk.url("x"), withIntermediateDirectories: true)
        try await ops.run(.copy([other.url("zeros.\(format.fileExtension)")], into: disk.url("x")))
        try disk.write("filler.bin", Data(count: 220 * 1024 * 1024))
        return disk.url("x/zeros.\(format.fileExtension)")
    }

    @Test func refusesBeforeExtractingAZipThatWontFit() async throws {
        let archive = try await archiveTooBigForTheDisk(.zip, megabytes: 400)
        let problem = await engine.extractionSpaceProblem(archive)
        #expect(problem?.contains("unpacks to") == true)
        await #expect(throws: OperationError.self) { try await ops.run(.extract(archive)) }
        #expect(try disk.names("x") == ["zeros.zip"])
    }

    @Test func stopsAndCleansUpWhenAnExtractionFillsTheDisk() async throws {
        let archive = try await archiveTooBigForTheDisk(.tarGz, megabytes: 400)
        // A compressed tar doesn't say its size up front, so this is only found while extracting.
        #expect(await engine.extractionSpaceProblem(archive) == nil)
        await #expect(throws: OperationError.self) { try await ops.run(.extract(archive)) }
        #expect(try disk.names("x") == ["zeros.tar.gz"])
    }

    @Test func extractsHardLinksAsHardLinks() async throws {
        try disk.write("linked/a.txt", "same data")
        try FileManager.default.linkItem(at: disk.url("linked/a.txt"), to: disk.url("linked/b.txt"))
        try TestVolume.run("/usr/bin/tar", ["-cf", disk.url("linked.tar").path, "-C", disk.work.path, "linked"])
        try FileManager.default.createDirectory(at: disk.url("out"), withIntermediateDirectories: true)
        try await ops.run(.move([disk.url("linked.tar")], into: disk.url("out")))

        let control = OperationControl()
        try await ops.run(.extract(disk.url("out/linked.tar")), control: control)
        #expect(control.skippedEntries.isEmpty)
        #expect(try disk.read("out/linked/b.txt") == "same data")
        #expect(FileEngine.isSameItem(disk.url("out/linked/a.txt").path, disk.url("out/linked/b.txt").path))
    }

    // MARK: - Path guard

    @Test func operationsRespectThePathGuard() async throws {
        try disk.write("a.txt", "a")
        let outside = FileManager.default.temporaryDirectory
        await #expect(throws: PathGuardViolation.self) {
            try await ops.run(.copy([disk.url("a.txt")], into: outside))
        }
        await #expect(throws: PathGuardViolation.self) {
            try await ops.run(.copy([URL(fileURLWithPath: "/etc/hosts")], into: disk.work))
        }
        let readOnly = OperationHarness(engine: FileEngine(pathGuard: .readOnly))
        await #expect(throws: PathGuardViolation.self) { try await readOnly.run(.trash([disk.url("a.txt")])) }
        #expect(disk.exists("a.txt"))
    }
}

/// A tiny ustar writer for building hostile archives in tests.
struct TarBuilder {
    private var blob = Data()

    func file(_ name: String, _ contents: String) -> TarBuilder {
        var copy = self
        let data = Data(contents.utf8)
        copy.blob += Self.header(name: name, size: data.count, type: "0", link: "")
        copy.blob += data
        copy.blob += Data(count: (512 - data.count % 512) % 512)
        return copy
    }

    func symlink(_ name: String, to target: String) -> TarBuilder {
        var copy = self
        copy.blob += Self.header(name: name, size: 0, type: "2", link: target)
        return copy
    }

    func data() -> Data {
        blob + Data(count: 1024)
    }

    private static func header(name: String, size: Int, type: String, link: String) -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ string: String, _ offset: Int, _ length: Int) {
            for (index, byte) in string.utf8.prefix(length).enumerated() { header[offset + index] = byte }
        }
        put(name, 0, 100)
        put("0000644", 100, 7)
        put("0000000", 108, 7)
        put("0000000", 116, 7)
        put(String(format: "%011o", size), 124, 11)
        put(String(format: "%011o", 0), 136, 11)
        put("        ", 148, 8)
        put(type, 156, 1)
        put(link, 157, 100)
        put("ustar", 257, 5)
        put("00", 263, 2)
        let checksum = header.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", checksum) + "\0 ", 148, 8)
        return Data(header)
    }
}

/// Deterministic randomness for repeatable random tests.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
