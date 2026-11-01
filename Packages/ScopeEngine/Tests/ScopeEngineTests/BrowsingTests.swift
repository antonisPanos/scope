import Foundation
import Testing
@testable import ScopeEngine

@Suite struct FileSortTests {
    let sandbox: Sandbox

    init() throws {
        sandbox = try Sandbox()
    }

    private func items() async throws -> [FileItem] {
        try await sandbox.engine.contentsOfDirectory(at: sandbox.root)
    }

    @Test func sortsNamesLikeFinder() async throws {
        for name in ["file 10.txt", "File 2.txt", "file 1.txt", "Apple.txt", "banana.txt"] {
            try sandbox.write(name, "x")
        }
        let names = FileSort(key: .name).sorted(try await items()).map(\.name)
        #expect(names == ["Apple.txt", "banana.txt", "file 1.txt", "File 2.txt", "file 10.txt"])
        let descending = FileSort(key: .name, ascending: false).sorted(try await items()).map(\.name)
        #expect(descending == names.reversed())
    }

    @Test func sortsBySizeWithFoldersFirstAndNameAsTieBreak() async throws {
        try sandbox.write("big.bin", Data(count: 300))
        try sandbox.write("b-small.bin", Data(count: 10))
        try sandbox.write("a-small.bin", Data(count: 10))
        try sandbox.mkdir("folder")
        let names = FileSort(key: .size).sorted(try await items()).map(\.name)
        #expect(names == ["folder", "a-small.bin", "b-small.bin", "big.bin"])
    }

    @Test func sortsByDate() async throws {
        let old = try sandbox.write("old.txt", "o")
        try sandbox.write("new.txt", "n")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)
        #expect(FileSort(key: .modified).sorted(try await items()).map(\.name) == ["old.txt", "new.txt"])
        #expect(FileSort(key: .modified, ascending: false).sorted(try await items()).map(\.name) == ["new.txt", "old.txt"])
    }

    @Test func describesKinds() async throws {
        try sandbox.write("doc.pdf", "%PDF")
        try sandbox.mkdir("folder")
        try sandbox.mkdir("App.app/Contents")
        try sandbox.symlink("link", to: "doc.pdf")
        let byName = Dictionary(uniqueKeysWithValues: try await items().map { ($0.name, $0) })
        #expect(byName["folder"]?.kind == "Folder")
        #expect(byName["link"]?.kind == "Symbolic link")
        #expect(byName["doc.pdf"]?.kind.localizedCaseInsensitiveContains("PDF") == true)
        #expect(byName["App.app"]?.isBrowsableFolder == false)
        #expect(byName["folder"]?.isBrowsableFolder == true)
    }
}

@Suite struct PathInputTests {
    let home = URL(fileURLWithPath: "/Users/someone")
    let current = URL(fileURLWithPath: "/Volumes/ScopeTest/names")

    private func resolve(_ text: String) -> String? {
        PathInput.resolve(text, relativeTo: current, home: home)?.path
    }

    @Test func absolutePaths() {
        #expect(resolve("/Volumes/ScopeTest") == "/Volumes/ScopeTest")
        #expect(resolve("/Volumes/ScopeTest/") == "/Volumes/ScopeTest")
        #expect(resolve("  /Volumes/ScopeTest/links\n") == "/Volumes/ScopeTest/links")
    }

    @Test func homeShortcuts() {
        #expect(resolve("~") == "/Users/someone")
        #expect(resolve("~/Documents") == "/Users/someone/Documents")
        #expect(resolve("$HOME/Desktop") == "/Users/someone/Desktop")
    }

    @Test func relativePaths() {
        #expect(resolve("deep") == "/Volumes/ScopeTest/names/deep")
        #expect(resolve("../links") == "/Volumes/ScopeTest/links")
        #expect(resolve("..") == "/Volumes/ScopeTest")
        #expect(PathInput.resolve("deep", relativeTo: nil, home: home) == nil)
    }

    @Test func pastedForms() {
        #expect(resolve("\"/Volumes/ScopeTest/My Folder\"") == "/Volumes/ScopeTest/My Folder")
        #expect(resolve("'/tmp/x'") == "/tmp/x")
        #expect(resolve("/Volumes/ScopeTest/My\\ Folder") == "/Volumes/ScopeTest/My Folder")
        #expect(resolve("file:///Volumes/ScopeTest/a%20b") == "/Volumes/ScopeTest/a b")
    }

    @Test func emptyInput() {
        #expect(resolve("") == nil)
        #expect(resolve("   ") == nil)
    }
}

@Suite struct FolderWatcherTests {
    @Test func reportsChangesToDirectChildren() async throws {
        let sandbox = try Sandbox()
        try sandbox.mkdir("watched/sub")
        let stream = try FolderWatcher.changes(in: sandbox.url("watched"), pathGuard: sandbox.engine.pathGuard, latency: 0.05)

        // FSEvents needs a moment to start delivering.
        try await Task.sleep(for: .milliseconds(300))
        try sandbox.write("watched/new.txt", "new")

        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(received)
    }

    @Test func refusesFoldersOutsideTheGuard() throws {
        let sandbox = try Sandbox()
        #expect(throws: PathGuardViolation.self) {
            _ = try FolderWatcher.changes(in: URL(fileURLWithPath: "/etc"), pathGuard: sandbox.engine.pathGuard)
        }
    }
}

@Suite struct VolumesTests {
    @Test func listsTheStartupDiskFirst() {
        let volumes = Volumes.mounted()
        #expect(volumes.first?.isRootVolume == true)
        #expect(volumes.first?.isEjectable == false)
    }

    @Test(.enabled(if: Sandbox.testDiskMounted, "needs the test disk"))
    func recognisesTheTestDiskAsADiskImage() throws {
        let testDisk = try #require(Volumes.mounted().first { $0.url.path == Sandbox.testDisk.path })
        #expect(testDisk.name == "ScopeTest")
        #expect(testDisk.isEjectable)
        #expect(testDisk.imagePath?.hasSuffix("ScopeTest.sparsebundle") == true)
    }

    @Test func ejectRespectsThePathGuard() async throws {
        let sandbox = try Sandbox()
        await #expect(throws: PathGuardViolation.self) {
            try await Volumes.eject(URL(fileURLWithPath: "/"), pathGuard: sandbox.engine.pathGuard)
        }
    }
}

@Suite struct PermitsTests {
    @Test func permitsWithoutThrowing() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        let pathGuard = sandbox.engine.pathGuard
        #expect(pathGuard.permits(sandbox.url("a.txt")))
        #expect(!pathGuard.permits(URL(fileURLWithPath: "/etc")))
        #expect(PathGuard.readOnly.permits(URL(fileURLWithPath: "/etc")))
    }
}

@Suite struct ItemDetailsTests {
    @Test func describesAFolderAnImageAndALink() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("folder/a.txt", "a")
        try sandbox.write("folder/b.txt", "b")
        try sandbox.write("folder/.hidden", "h")
        try sandbox.symlink("link", to: "folder")

        // A 3 x 2 PNG.
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAEklEQVR4nGP4z8DwnwEIQSwAP90E/GlZz9YAAAAASUVORK5CYII="))
        try sandbox.write("image.png", png)

        let folder = try await sandbox.engine.details(for: sandbox.url("folder"))
        #expect(folder.folderItemCount == 2)

        let image = try await sandbox.engine.details(for: sandbox.url("image.png"))
        #expect(image.pixelWidth == 3 && image.pixelHeight == 2)

        let link = try await sandbox.engine.details(for: sandbox.url("link"))
        #expect(link.linkTarget == "folder")
    }

    @Test func refusesItemsOutsideTheGuard() async throws {
        let sandbox = try Sandbox()
        await #expect(throws: PathGuardViolation.self) {
            try await sandbox.engine.details(for: URL(fileURLWithPath: "/etc/hosts"))
        }
        await #expect(throws: PathGuardViolation.self) {
            try await sandbox.engine.folderSize(of: URL(fileURLWithPath: "/etc"))
        }
    }

    @Test func addsUpAFolderWithoutFollowingLinks() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("f/a.bin", Data(count: 1_000))
        try sandbox.write("f/sub/b.bin", Data(count: 500))
        try sandbox.write("f/.hidden", Data(count: 20))
        try sandbox.symlink("f/loop", to: "..")
        let size = try await sandbox.engine.folderSize(of: sandbox.url("f"))
        #expect(size.bytes == 1_520)
        #expect(size.items == 5)
        #expect(size.allocatedBytes >= size.bytes)

        chmod(sandbox.url("f/a.bin").path, 0o640)
        let details = try await sandbox.engine.details(for: sandbox.url("f/a.bin"))
        #expect(details.permissions == "rw-r-----")
        #expect(details.owner == NSUserName())
    }
}
