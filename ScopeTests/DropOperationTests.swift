import AppKit
import ScopeEngine
import Testing

@testable import Scope

/// The move or copy badge of a drag, which runs on every mouse move and must
/// decide without touching the disk.
@MainActor
struct DropOperationTests {
    let mounts = MountTable(mountPoints: ["/Volumes/A", "/Volumes/B"])

    func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func operation(_ paths: [String], into folder: String, option: Bool = false) -> NSDragOperation {
        FileViewKeys.dropOperation(paths.map(url), into: url(folder), optionHeld: option, mounts: mounts)
    }

    @Test func movesWithinOneDisk() {
        #expect(operation(["/Volumes/A/x.txt", "/Volumes/A/sub/y.txt"], into: "/Volumes/A/target") == .move)
    }

    @Test func copiesFromAnotherDisk() {
        #expect(operation(["/Volumes/B/x.txt"], into: "/Volumes/A/target") == .copy)
        // One item from elsewhere is enough to copy them all.
        #expect(operation(["/Volumes/A/x.txt", "/Volumes/B/y.txt"], into: "/Volumes/A/target") == .copy)
    }

    @Test func optionAlwaysCopies() {
        #expect(operation(["/Volumes/A/x.txt"], into: "/Volumes/A/target", option: true) == .copy)
    }

    @Test func refusesAFolderIntoItselfOrItsOwnSubfolder() {
        #expect(operation(["/Volumes/A/folder"], into: "/Volumes/A/folder") == [])
        #expect(operation(["/Volumes/A/folder"], into: "/Volumes/A/folder/inside") == [])
        // A sibling whose name only starts the same is fine.
        #expect(operation(["/Volumes/A/folder"], into: "/Volumes/A/folder2") == .move)
    }

    @Test func refusesTheFolderTheItemsAreAlreadyIn() {
        #expect(operation(["/Volumes/A/target/x.txt", "/Volumes/A/target/y.txt"], into: "/Volumes/A/target") == [])
        #expect(operation([], into: "/Volumes/A/target") == [])
    }

    @Test func theRealMountTableTellsDisksApart() {
        // /dev is a file system of its own on every Mac.
        let real = MountTable()
        let temp = FileManager.default.temporaryDirectory
        let here = FileViewKeys.dropOperation(
            [temp.appendingPathComponent("a.txt")], into: temp.appendingPathComponent("folder"), optionHeld: false,
            mounts: real)
        let fromDev = FileViewKeys.dropOperation(
            [url("/dev/null")], into: temp.appendingPathComponent("folder"), optionHeld: false, mounts: real)
        #expect(here == .move)
        #expect(fromDev == .copy)
    }
}
