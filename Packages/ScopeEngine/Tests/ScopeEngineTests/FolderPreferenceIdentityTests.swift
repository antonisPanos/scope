import Dispatch
import Foundation
import Testing

@testable import ScopeEngine

@Suite struct LocalFolderIdentityTests {
    @Test @MainActor func guardedIdentityReadsRunOnIOThreadsAndFollowAllowedLinks() async throws {
        let sandbox = try Sandbox()
        try sandbox.mkdir("folder")
        try sandbox.symlink("link", to: "folder")
        let queues = Recorded<String>()
        var engine = sandbox.engine
        engine.readValidationHook = {
            queues.append(String(cString: __dispatch_queue_get_label(nil)))
            #expect(!Thread.isMainThread)
        }
        let identity = try #require(await engine.folderPreferenceIdentity(at: sandbox.url("folder")))
        #expect(await engine.folderPreferenceIdentity(at: sandbox.url("link")) == identity)
        #expect(queues.all == [IOExecutor.label, IOExecutor.label])
        #expect(await engine.folderPreferenceIdentity(at: sandbox.url("missing")) == nil)
        let file = try sandbox.write("file.txt", "not a directory")
        #expect(await engine.folderPreferenceIdentity(at: file) == nil)
        #expect(await FileEngine(pathGuard: .denyAll).folderPreferenceIdentity(at: sandbox.url("folder")) == nil)
        try sandbox.symlink("escape", to: NSHomeDirectory())
        #expect(await engine.folderPreferenceIdentity(at: sandbox.url("escape")) == nil)
    }
}

/// Mounted-image integration tests run with the full engine suite on isolated
/// CI/VM hosts, as documented in CONTRIBUTING.md.
@Suite struct FolderPreferenceVolumeTests {
    @Test func identityFollowsSameVolumeRenamesButNotCopiesOrPathReuse() async throws {
        let volume = try TestVolume(name: "ScopeViewID", sizeMB: 64)
        let sandbox = try Sandbox(in: volume.work)
        let engine = sandbox.engine
        try sandbox.mkdir("original")
        try sandbox.mkdir("parent")
        let original = try #require(await engine.folderPreferenceIdentity(at: sandbox.url("original")))
        let renamed = try await engine.rename(sandbox.url("original"), to: "renamed")
        #expect(await engine.folderPreferenceIdentity(at: renamed) == original)
        try await engine.moveItem(at: renamed, to: sandbox.url("parent/moved"))
        #expect(await engine.folderPreferenceIdentity(at: sandbox.url("parent/moved")) == original)
        try await engine.copyItem(at: sandbox.url("parent/moved"), to: sandbox.url("copy"))
        #expect(try #require(await engine.folderPreferenceIdentity(at: sandbox.url("copy"))) != original)
        try await engine.createFolder(at: sandbox.url("original"))
        #expect(try #require(await engine.folderPreferenceIdentity(at: sandbox.url("original"))) != original)
    }

    @Test func identitySurvivesRemountAndDoesNotCrossVolumes() async throws {
        let first = try TestVolume(name: "ScopeViewA", sizeMB: 64)
        let second = try TestVolume(name: "ScopeViewB", sizeMB: 64)
        let engine = FileEngine(pathGuard: .restricted(to: [first.work, second.work]))
        try await engine.createFolder(at: first.url("folder"))
        let original = try #require(await engine.folderPreferenceIdentity(at: first.url("folder")))
        try first.remount()
        #expect(await engine.folderPreferenceIdentity(at: first.url("folder")) == original)
        // Both the source and the destination are disposable volumes, including
        // the source Trash used by a cross-volume move.
        try await OperationHarness(engine: engine).run(.move([first.url("folder")], into: second.work))
        let moved = try #require(await engine.folderPreferenceIdentity(at: second.url("folder")))
        #expect(moved != original && moved.volumeUUID != original.volumeUUID)
        try second.detach()
        #expect(await engine.folderPreferenceIdentity(at: second.url("folder")) == nil)
    }

    @Test func volumesWithoutPersistentObjectIDsReturnNil() async throws {
        let volume = try TestVolume(name: "SCOPEVIEW", sizeMB: 64, fileSystem: "MS-DOS FAT32")
        let engine = FileEngine(pathGuard: .restricted(to: [volume.work]))
        try await engine.createFolder(at: volume.url("folder"))
        #expect(await engine.folderPreferenceIdentity(at: volume.url("folder")) == nil)
    }
}
