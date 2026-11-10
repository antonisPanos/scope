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

    @Test func readsAFilesContents() async throws {
        try sandbox.write("doc.txt", "hello")
        #expect(try await engine.contents(of: sandbox.url("doc.txt")) == Data("hello".utf8))
        await #expect(throws: FileEngineError.tooLarge(sandbox.url("doc.txt").path)) {
            try await engine.contents(of: sandbox.url("doc.txt"), limit: 4)
        }
        try sandbox.mkdir("folder")
        await #expect(throws: FileEngineError.self) { try await engine.contents(of: sandbox.url("folder")) }
        await #expect(throws: PathGuardViolation.self) {
            try await engine.contents(of: URL(fileURLWithPath: NSHomeDirectory() + "/.zshrc"))
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

    @Test func trashesASymlinkWithoutTouchingItsTarget() async throws {
        // Both folders live on a throwaway disk image, so nothing can reach
        // the user's real Trash. The link points outside the guard's root;
        // trashing the link is allowed, and its target must survive.
        let volume = try TestVolume(name: "ScopeLinks", sizeMB: 64)
        let disk = try Sandbox(in: volume.work)
        let outside = try Sandbox(in: volume.work)
        let target = try outside.write("target.txt", "keep")
        try disk.symlink("link", to: target.path)

        let trashed = try await disk.engine.trashItem(at: disk.url("link"))
        defer { if let trashed { try? FileManager.default.removeItem(at: trashed) } }
        #expect(trashed?.path.hasPrefix(volume.mountPoint.path + "/") == true)
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

        let engine = self.engine
        let source = sandbox.url("big")
        let target = sandbox.url("dest/big")
        // Cancelled from the copy's own progress report, after the first
        // chunk, so the test doesn't depend on when its own task gets a thread
        // (other suites keep the pool busy, and the copy could finish first).
        let handle = Mutex<Task<Void, Error>?>(nil)
        let cancelledAt = Mutex<ContinuousClock.Instant?>(nil)
        let stoppedAt = Mutex<ContinuousClock.Instant?>(nil)
        let ready = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            for await _ in ready.stream { break }
            // Timed on the engine's threads too, for the same reason.
            try await onIOThreads {
                defer { stoppedAt.withLock { $0 = .now } }
                try await engine.copyItem(at: source, to: target) { progress in
                    guard progress.bytesDone > 0, cancelledAt.withLock({ $0 == nil }) else { return }
                    cancelledAt.withLock { $0 = .now }
                    handle.withLock { $0?.cancel() }
                }
            }
        }
        handle.withLock { $0 = task }
        ready.continuation.yield()
        await #expect(throws: CancellationError.self) { try await task.value }

        let cancelled = try #require(cancelledAt.withLock { $0 })
        let stopped = try #require(stoppedAt.withLock { $0 })
        #expect(stopped - cancelled < .milliseconds(500))
        #expect(try sandbox.names(in: "dest") == [])
    }

    @Test func refusesPrefixOnlyPartialCleanup() async throws {
        try sandbox.write("folder/\(FileEngine.partialPrefix)1234-a.txt", "half")
        try sandbox.write("folder/kept.txt", "kept")
        await #expect(throws: CocoaError.self) {
            try await engine.removeLeftoverPartials(in: sandbox.url("folder"))
        }
        #expect(try sandbox.names(in: "folder") == [".scope-partial-1234-a.txt", "kept.txt"])
    }
}
