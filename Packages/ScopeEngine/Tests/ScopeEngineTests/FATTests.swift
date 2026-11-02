import Foundation
import Testing

@testable import ScopeEngine

/// FAT and exFAT disks (most USB sticks and SD cards) can't rename
/// exclusively. Copies, moves and renames still work there, and still never
/// replace an item that is already in place.
@Suite(.serialized) struct FATTests {
    let disk: TestVolume
    let fat: TestVolume
    let ops: OperationHarness

    init() throws {
        disk = try TestVolume(name: "ScopeFATSource")
        fat = try TestVolume(name: "SCOPEFATOPS", sizeMB: 128, fileSystem: "MS-DOS FAT32")
        ops = OperationHarness(engine: FileEngine(pathGuard: .restricted(to: [disk.mountPoint, fat.mountPoint])))
    }

    @Test func copiesFilesAndFoldersOnto() async throws {
        try disk.write("one.txt", "one")
        try disk.write("folder/inner/two.txt", "two")
        try await ops.run(.copy([disk.url("one.txt"), disk.url("folder")], into: fat.work))
        #expect(try fat.read("one.txt") == "one")
        #expect(try fat.read("folder/inner/two.txt") == "two")
        // No placeholder or partial copy is left behind.
        #expect(try fat.names() == ["folder", "one.txt"])
    }

    @Test func renamesAndMovesWithinIt() async throws {
        try fat.write("a.txt", "a")
        try fat.write("box/kept.txt", "kept")
        try await ops.run(.rename(fat.url("a.txt"), to: "b.txt"))
        try await ops.run(.move([fat.url("b.txt")], into: fat.url("box")))
        #expect(try fat.names() == ["box"])
        #expect(try fat.read("box/b.txt") == "a")
        #expect(try fat.read("box/kept.txt") == "kept")
    }

    @Test func neverReplacesWhatIsThere() throws {
        let source = try fat.write("new.txt", "new")
        let existing = try fat.write("old.txt", "old")
        #expect(!FileEngine.renameExclusively(source.path, to: existing.path))
        #expect(errno == EEXIST)
        #expect(try fat.read("new.txt") == "new")
        #expect(try fat.read("old.txt") == "old")

        try fat.write("folder/x.txt", "x")
        try fat.write("taken/y.txt", "y")
        #expect(!FileEngine.renameExclusively(fat.url("folder").path, to: fat.url("taken").path))
        #expect(try fat.names("taken") == ["y.txt"])
        #expect(try fat.names("folder") == ["x.txt"])
    }
}
