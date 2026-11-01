import Foundation
import Testing

@testable import ScopeEngine

@Suite struct MountTableTests {
    @Test func picksTheInnermostMountPoint() {
        let table = MountTable(mountPoints: ["/", "/Volumes/Disk", "/Volumes/Disk Two", "/Volumes/Disk/inner"])
        #expect(table.mountPoint(of: "/Users/someone/file") == "/")
        #expect(table.mountPoint(of: "/Volumes/Disk") == "/Volumes/Disk")
        #expect(table.mountPoint(of: "/Volumes/Disk/a/b") == "/Volumes/Disk")
        #expect(table.mountPoint(of: "/Volumes/Disk Two/a") == "/Volumes/Disk Two")
        #expect(table.mountPoint(of: "/Volumes/Disk/inner/a") == "/Volumes/Disk/inner")
        // A name that only starts like a mount point is not on it.
        #expect(table.mountPoint(of: "/Volumes/Disk2/a") == "/")
    }

    @Test func comparesTheDisksOfADrop() {
        let table = MountTable(mountPoints: ["/Volumes/A", "/Volumes/B"])
        let url = { (path: String) in URL(fileURLWithPath: path) }
        let folder = url("/Volumes/A/folder")
        #expect(table.seemOnSameDisk([url("/Volumes/A/x"), url("/Volumes/A/y/z")], as: folder))
        #expect(!table.seemOnSameDisk([url("/Volumes/A/x"), url("/Volumes/B/y")], as: folder))
        #expect(!table.seemOnSameDisk([url("/tmp/x")], as: folder))
    }

    @Test func readsTheKernelsMountTable() {
        let table = MountTable()
        #expect(table.mountPoints.contains("/"))
        #expect(table.mountPoints.count > 1)
        #expect(table.mountPoints == table.mountPoints.sorted { $0.count > $1.count })
    }
}

@Suite(.serialized) struct SameDiskTests {
    let sandbox: Sandbox

    init() throws {
        sandbox = try Sandbox()
    }

    @Test func itemsInOneFolderAreOnItsDisk() async throws {
        let a = try sandbox.write("a.txt", "a")
        let b = try sandbox.write("sub/b.txt", "b")
        try sandbox.mkdir("target")
        #expect(await sandbox.engine.areOnSameDisk([a, b], as: sandbox.url("target")))
    }

    @Test func missingOrRefusedItemsAreNotOnTheDisk() async throws {
        let a = try sandbox.write("a.txt", "a")
        try sandbox.mkdir("target")
        #expect(!(await sandbox.engine.areOnSameDisk([a, sandbox.url("gone.txt")], as: sandbox.url("target"))))
        #expect(!(await sandbox.engine.areOnSameDisk([a], as: sandbox.url("no-such-folder"))))
        let other = try Sandbox()
        let outside = try other.write("elsewhere.txt", "x")
        #expect(!(await sandbox.engine.areOnSameDisk([a, outside], as: sandbox.url("target"))))
    }

    @Test func anotherDiskIsNotTheSameDisk() async throws {
        let volume = try TestVolume(name: "ScopeDisks", sizeMB: 64)
        let onVolume = try volume.write("x.txt", "x")
        let local = try sandbox.write("y.txt", "y")
        let engine = FileEngine(pathGuard: .restricted(to: [sandbox.root, volume.mountPoint]))
        #expect(!(await engine.areOnSameDisk([onVolume], as: sandbox.root)))
        #expect(!(await engine.areOnSameDisk([local, onVolume], as: volume.work)))
        #expect(await engine.areOnSameDisk([onVolume], as: volume.work))
        // The guess from the mount table agrees, without asking either disk.
        let table = MountTable()
        #expect(table.mountPoint(of: onVolume.path) == volume.mountPoint.path)
        #expect(!table.seemOnSameDisk([onVolume], as: sandbox.root))
        #expect(table.seemOnSameDisk([onVolume], as: volume.work))
    }
}
