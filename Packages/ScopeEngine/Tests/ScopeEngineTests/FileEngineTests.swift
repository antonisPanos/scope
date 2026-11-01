import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

@Suite struct FileEngineTests {
    let sandbox: Sandbox
    var engine: FileEngine { sandbox.engine }

    init() throws {
        sandbox = try Sandbox()
    }

    // MARK: - Listing

    @Test func listsAFolder() async throws {
        try sandbox.write("folder/b.txt", "hello")
        try sandbox.write("folder/.hidden", "h")
        try sandbox.mkdir("folder/sub")
        try sandbox.symlink("folder/link", to: "b.txt")

        let items = try await engine.contentsOfDirectory(at: sandbox.url("folder"))
        #expect(items.map(\.name).sorted() == [".hidden", "b.txt", "link", "sub"])
        let file = try #require(items.first { $0.name == "b.txt" })
        #expect(file.size == 5 && !file.isDirectory)
        #expect(items.first { $0.name == "sub" }?.isDirectory == true)
        #expect(items.first { $0.name == "link" }?.isSymbolicLink == true)

        let visible = try await engine.contentsOfDirectory(at: sandbox.url("folder"), includeHidden: false)
        #expect(!visible.contains { $0.name == ".hidden" })
    }

    @Test func refusesToListOutsideTheRoot() async throws {
        await #expect(throws: PathGuardViolation.self) {
            try await engine.contentsOfDirectory(at: URL(fileURLWithPath: NSHomeDirectory()))
        }
    }

    // MARK: - Create, rename, move, trash

    @Test func createsAFolder() async throws {
        try await engine.createFolder(at: sandbox.url("new"))
        #expect(sandbox.exists("new"))
        await #expect(throws: FileEngineError.destinationExists(sandbox.url("new").path)) {
            try await engine.createFolder(at: sandbox.url("new"))
        }
    }

    @Test func renames() async throws {
        try sandbox.write("a.txt", "a")
        try sandbox.write("b.txt", "b")
        let renamed = try await engine.rename(sandbox.url("a.txt"), to: "c.txt")
        #expect(renamed.lastPathComponent == "c.txt")
        #expect(try sandbox.names() == ["b.txt", "c.txt"])

        // Never overwrites.
        await #expect(throws: FileEngineError.self) { try await engine.rename(sandbox.url("c.txt"), to: "b.txt") }
        #expect(try String(contentsOf: sandbox.url("b.txt"), encoding: .utf8) == "b")
    }

    @Test(arguments: ["", ".", "..", "a/b", "../escape"])
    func refusesInvalidNames(_ name: String) async throws {
        try sandbox.write("a.txt", "a")
        await #expect(throws: FileEngineError.invalidName(name)) {
            try await engine.rename(sandbox.url("a.txt"), to: name)
        }
    }

    @Test func renamesOnlyTheCase() async throws {
        try sandbox.write("readme.txt", "r")
        try await engine.rename(sandbox.url("readme.txt"), to: "README.txt")
        #expect(try sandbox.names() == ["README.txt"])
    }

    @Test func movesWithinADisk() async throws {
        try sandbox.write("from/a.txt", "a")
        try sandbox.mkdir("to")
        try await engine.moveItem(at: sandbox.url("from/a.txt"), to: sandbox.url("to/a.txt"))
        #expect(!sandbox.exists("from/a.txt"))
        #expect(try String(contentsOf: sandbox.url("to/a.txt"), encoding: .utf8) == "a")
    }

    @Test func moveNeverOverwrites() async throws {
        try sandbox.write("a.txt", "a")
        try sandbox.write("b.txt", "b")
        await #expect(throws: FileEngineError.self) {
            try await engine.moveItem(at: sandbox.url("a.txt"), to: sandbox.url("b.txt"))
        }
        #expect(try String(contentsOf: sandbox.url("b.txt"), encoding: .utf8) == "b")
    }

    @Test func refusesToMoveAFolderIntoItself() async throws {
        try sandbox.mkdir("folder/sub")
        await #expect(throws: FileEngineError.cannotCopyIntoItself(sandbox.url("folder").path)) {
            try await engine.moveItem(at: sandbox.url("folder"), to: sandbox.url("folder/sub/folder"))
        }
    }

    @Test func refusesToMoveOutOfTheRoot() async throws {
        try sandbox.write("a.txt", "a")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("scope-escape-\(UUID().uuidString)")
        await #expect(throws: PathGuardViolation.self) {
            try await engine.moveItem(at: sandbox.url("a.txt"), to: outside)
        }
        #expect(sandbox.exists("a.txt"))
    }

    @Test(.enabled(if: Sandbox.testDiskMounted, "needs the test disk, so the user's real Trash is never used"))
    func trashesASymlinkWithoutTouchingItsTarget() async throws {
        // Both folders live on the test disk, so the item goes to that disk's
        // own Trash. The link points outside the guard's root; trashing the
        // link is allowed, and its target must survive.
        let disk = try Sandbox(in: Sandbox.testDisk)
        let outside = try Sandbox(in: Sandbox.testDisk)
        let target = try outside.write("target.txt", "keep")
        try disk.symlink("link", to: target.path)

        let trashed = try await disk.engine.trashItem(at: disk.url("link"))
        defer { if let trashed { try? FileManager.default.removeItem(at: trashed) } }
        #expect(trashed?.path.hasPrefix(Sandbox.testDisk.path + "/") == true)
        #expect(!disk.exists("link"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
    }

    @Test func refusesToTrashOutsideTheRoot() async throws {
        let outside = try Sandbox()
        try outside.write("a.txt", "a")
        await #expect(throws: PathGuardViolation.self) { try await engine.trashItem(at: outside.url("a.txt")) }
        #expect(outside.exists("a.txt"))
    }

    // MARK: - Read-only guard

    @Test func readOnlyGuardListsButRefusesEveryChange() async throws {
        try sandbox.write("a.txt", "a")
        try sandbox.mkdir("folder")
        let readOnly = FileEngine(pathGuard: .readOnly)
        let before = try TreeSnapshot(sandbox.root)

        #expect(try await readOnly.contentsOfDirectory(at: sandbox.root).count == 2)
        await #expect(throws: PathGuardViolation.self) { try await readOnly.createFolder(at: sandbox.url("new")) }
        await #expect(throws: PathGuardViolation.self) { try await readOnly.rename(sandbox.url("a.txt"), to: "b.txt") }
        await #expect(throws: PathGuardViolation.self) {
            try await readOnly.moveItem(at: sandbox.url("a.txt"), to: sandbox.url("folder/a.txt"))
        }
        await #expect(throws: PathGuardViolation.self) {
            try await readOnly.copyItem(at: sandbox.url("a.txt"), to: sandbox.url("copy.txt"))
        }
        await #expect(throws: PathGuardViolation.self) { try await readOnly.trashItem(at: sandbox.url("a.txt")) }
        let error = await #expect(throws: PathGuardViolation.self) {
            try await readOnly.removeLeftoverPartials(in: sandbox.root)
        }
        #expect(error?.reason == .writesDisabled)

        #expect(try TreeSnapshot(sandbox.root) == before)
    }

    // MARK: - Copy

    private static func freeBytes(_ path: String) -> Int64? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    @Test func clonesWithinOneAPFSVolume() async throws {
        let volume = try TestVolume(name: "ScopeClone")
        let engine = FileEngine(pathGuard: .restricted(to: [volume.mountPoint]))
        var bytes = Data(count: 200 * 1024 * 1024)
        bytes[0] = 1
        bytes[bytes.count - 1] = 2
        try volume.write("big.bin", bytes)
        bytes = Data()
        // Flushed, so the disk has allocated it before free space is measured.
        let written = try FileHandle(forWritingTo: volume.url("big.bin"))
        try written.synchronize()
        try written.close()
        let before = try #require(Self.freeBytes(volume.work.path))

        try await engine.copyItem(at: volume.url("big.bin"), to: volume.url("clone.bin"))
        let after = try #require(Self.freeBytes(volume.work.path))
        // A clone shares the original's storage; a byte copy would take 200 MB.
        #expect(before - after < 50 * 1024 * 1024)
        let copy = try Data(contentsOf: volume.url("clone.bin"), options: .alwaysMapped)
        #expect(copy.count == 200 * 1024 * 1024 && copy.first == 1 && copy.last == 2)
    }

    @Test func sparseFilesStaySparse() async throws {
        try sandbox.write("sparse.bin", Data())
        let size: off_t = 300 * 1024 * 1024
        let handle = try FileHandle(forWritingTo: sandbox.url("sparse.bin"))
        try handle.truncate(atOffset: UInt64(size))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 7, count: 1024 * 1024))
        try handle.seek(toOffset: UInt64(size) / 2)
        try handle.write(contentsOf: Data(repeating: 8, count: 1024 * 1024))
        try handle.close()
        let sourceBlocks = try #require(FileEngine.lstatInfo(sandbox.url("sparse.bin").path)).st_blocks
        try #require(Int64(sourceBlocks) * 512 < Int64(size) / 10, "the temp disk doesn't keep files sparse")

        // Onto another disk, so the copy can't be a clone.
        let volume = try TestVolume(name: "ScopeSparse")
        let engine = FileEngine(pathGuard: .restricted(to: [sandbox.root, volume.mountPoint]))
        let progress = Mutex<CopyProgress?>(nil)
        try await engine.copyItem(at: sandbox.url("sparse.bin"), to: volume.url("sparse.bin")) { report in
            progress.withLock { $0 = report }
        }
        let info = try #require(FileEngine.lstatInfo(volume.url("sparse.bin").path))
        #expect(info.st_size == size)
        #expect(Int64(info.st_blocks) * 512 < 16 * 1024 * 1024)
        #expect(progress.withLock { $0?.bytesDone } == Int64(size))
        let copy = try Data(contentsOf: volume.url("sparse.bin"), options: .alwaysMapped)
        #expect(copy[0] == 7 && copy[Int(size) / 2] == 8 && copy[Int(size) / 4] == 0 && copy.last == 0)
    }

    @Test func copiesAFileWithItsMetadata() async throws {
        let source = try sandbox.write("a.txt", "contents")
        setXattr(source, "com.example.note", "kept")
        chmod(source.path, 0o640)
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: source.path)

        try await engine.copyItem(at: source, to: sandbox.url("b.txt"))

        let before = try TreeSnapshot(source)
        let after = try TreeSnapshot(sandbox.url("b.txt"))
        #expect(before == after)
        let modified =
            try FileManager.default.attributesOfItem(atPath: sandbox.url("b.txt").path)[.modificationDate] as? Date
        #expect(modified == old)
    }

    @Test func copiesATreeExactly() async throws {
        try sandbox.write("tree/a.txt", "a")
        try sandbox.write("tree/sub/b.bin", Data((0..<10_000).map { UInt8($0 % 251) }))
        try sandbox.write("tree/sub/deeper/empty", Data())
        try sandbox.write("tree/Café é.txt", "unicode")
        try sandbox.write("tree/🦊.txt", "emoji")
        try sandbox.mkdir("tree/App.app/Contents")
        try sandbox.symlink("tree/link-in", to: "sub/b.bin")
        try sandbox.symlink("tree/link-out", to: "/etc/hosts")
        try sandbox.symlink("tree/dangling", to: "nowhere")
        setXattr(sandbox.url("tree/sub"), "com.example.folder", "x")
        chmod(sandbox.url("tree/sub/deeper").path, 0o555)
        chmod(sandbox.url("tree/a.txt").path, 0o444)

        try await engine.copyItem(at: sandbox.url("tree"), to: sandbox.url("copy"))

        #expect(try TreeSnapshot(sandbox.url("tree")) == TreeSnapshot(sandbox.url("copy")))
        // The link pointing outside was copied as a link, not followed.
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: sandbox.url("copy/link-out").path) == "/etc/hosts"
        )
    }

    @Test func copiesLockedFilesAndKeepsThemLocked() async throws {
        try sandbox.write("tree/locked.txt", "locked")
        chflags(sandbox.url("tree/locked.txt").path, UInt32(UF_IMMUTABLE))

        try await engine.copyItem(at: sandbox.url("tree"), to: sandbox.url("copy"))

        let flags = try #require(FileEngine.lstatInfo(sandbox.url("copy/locked.txt").path)).st_flags
        #expect(flags & UInt32(UF_IMMUTABLE) != 0)
        #expect(try TreeSnapshot(sandbox.url("tree")) == TreeSnapshot(sandbox.url("copy")))
    }

    @Test func copyNeverOverwrites() async throws {
        try sandbox.write("a.txt", "a")
        try sandbox.write("b.txt", "b")
        await #expect(throws: FileEngineError.destinationExists(sandbox.url("b.txt").path)) {
            try await engine.copyItem(at: sandbox.url("a.txt"), to: sandbox.url("b.txt"))
        }
        #expect(try String(contentsOf: sandbox.url("b.txt"), encoding: .utf8) == "b")
    }

    @Test func refusesToCopyAFolderIntoItself() async throws {
        try sandbox.mkdir("folder")
        await #expect(throws: FileEngineError.cannotCopyIntoItself(sandbox.url("folder").path)) {
            try await engine.copyItem(at: sandbox.url("folder"), to: sandbox.url("folder/copy"))
        }
    }

    @Test func refusesToCopyFromOrToOutsideTheRoot() async throws {
        try sandbox.write("a.txt", "a")
        await #expect(throws: PathGuardViolation.self) {
            try await engine.copyItem(at: URL(fileURLWithPath: "/etc/hosts"), to: sandbox.url("hosts"))
        }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("scope-escape-\(UUID().uuidString)")
        await #expect(throws: PathGuardViolation.self) {
            try await engine.copyItem(at: sandbox.url("a.txt"), to: outside)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func reportsProgress() async throws {
        try sandbox.write("tree/a", Data(count: 10))
        try sandbox.write("tree/b", Data(count: FileEngine.chunkSize + 5))
        let last = Mutex<CopyProgress?>(nil)
        try await engine.copyItem(at: sandbox.url("tree"), to: sandbox.url("copy")) { progress in
            last.withLock { $0 = progress }
        }
        let final = try #require(last.withLock { $0 })
        #expect(final.bytesTotal == Int64(FileEngine.chunkSize + 15))
        #expect(final.bytesDone == final.bytesTotal)
        #expect(final.itemsTotal == 3 && final.itemsDone == 3)
    }

    @Test func cancelLeavesNothingBehind() async throws {
        // Big enough that the copy is still running when it gets cancelled.
        try sandbox.write("big/one.bin", Data(count: 64 * 1024 * 1024))
        try sandbox.write("big/two.bin", Data(count: 64 * 1024 * 1024))
        try sandbox.mkdir("dest")
        let started = AsyncStream.makeStream(of: Void.self)

        let engine = self.engine
        let source = sandbox.url("big")
        let target = sandbox.url("dest/big")
        let task = Task {
            try await engine.copyItem(at: source, to: target) { progress in
                if progress.bytesDone > 0 { started.continuation.yield() }
            }
        }
        for await _ in started.stream { break }
        let cancelledAt = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(ContinuousClock.now - cancelledAt < .milliseconds(500))
        #expect(try sandbox.names(in: "dest") == [])
    }

    @Test func removesLeftoverPartials() async throws {
        try sandbox.write("folder/\(FileEngine.partialPrefix)1234-a.txt", "half")
        try sandbox.write("folder/kept.txt", "kept")
        let removed = try await engine.removeLeftoverPartials(in: sandbox.url("folder"))
        #expect(removed == 1)
        #expect(try sandbox.names(in: "folder") == ["kept.txt"])
    }
}
