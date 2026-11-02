import Foundation
import Testing

@testable import ScopeEngine

/// Network shares are polled, since FSEvents doesn't hear about changes other
/// machines make there; local disks use FSEvents.
@Suite struct WatcherBackendTests {
    @Test func networkSharesArePolled() {
        let mounts = MountTable(mountPoints: ["/Volumes/Share", "/Volumes/USB"], networkMounts: ["/Volumes/Share"])
        #expect(mounts.isNetwork("/Volumes/Share/folder"))
        #expect(!mounts.isNetwork("/Volumes/USB/folder"))
        #expect(!mounts.isNetwork("/Users/someone"))
        let share = URL(fileURLWithPath: "/Volumes/Share/folder")
        #expect(FolderWatcher.Backend.automatic(for: share, mounts: mounts) == .polling(interval: .seconds(3)))
        let local = URL(fileURLWithPath: "/Volumes/USB/folder")
        #expect(FolderWatcher.Backend.automatic(for: local, mounts: mounts) == .fsEvents)
    }

    @Test func theStartupDiskIsLocal() {
        #expect(!MountTable().isNetwork("/"))
    }

    @Test func snapshotsNameWhatChanged() throws {
        let sandbox = try Sandbox()
        try sandbox.write("folder/kept.txt", "k")
        try sandbox.write("folder/edited.txt", "e")
        try sandbox.write("folder/removed.txt", "r")
        let folder = sandbox.url("folder").path
        let before = FolderSnapshot.read(folder)
        #expect(FolderSnapshot.change(from: before, to: FolderSnapshot.read(folder)) == nil)

        try sandbox.write("folder/edited.txt", "edited")
        try FileManager.default.removeItem(at: sandbox.url("folder/removed.txt"))
        try sandbox.write("folder/added.txt", "a")
        let after = FolderSnapshot.read(folder)
        #expect(FolderSnapshot.change(from: before, to: after) == .children(["edited.txt", "removed.txt", "added.txt"]))

        // The folder going away (or coming back) means everything.
        #expect(FolderSnapshot.read(sandbox.url("missing").path) == nil)
        #expect(FolderSnapshot.change(from: after, to: nil) == .everything)
        #expect(FolderSnapshot.change(from: nil, to: after) == .everything)
        #expect(FolderSnapshot.change(from: nil, to: nil) == nil)
    }

    @Test func pollingReportsChangedNames() async throws {
        let sandbox = try Sandbox()
        try sandbox.mkdir("watched")
        let events = try FolderWatcher.events(
            in: sandbox.url("watched"), pathGuard: sandbox.engine.pathGuard,
            backend: .polling(interval: .milliseconds(100)))
        // Let the first snapshot be taken.
        try await Task.sleep(for: .milliseconds(300))
        try sandbox.write("watched/new.txt", "new")

        let seen = await withTaskGroup(of: FolderChange?.self) { group in
            group.addTask {
                for await change in events { return change }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(seen == .children(["new.txt"]))
    }

    @Test func pollingRespectsTheGuard() throws {
        let sandbox = try Sandbox()
        #expect(throws: PathGuardViolation.self) {
            _ = try FolderWatcher.events(
                in: URL(fileURLWithPath: "/etc"), pathGuard: sandbox.engine.pathGuard,
                backend: .polling(interval: .seconds(1)))
        }
    }
}
