import Foundation
import Testing

@testable import ScopeEngine

/// A copy is checked against its destination before anything is written:
/// free space, the largest file the disk can hold, and the names it allows.
@Suite(.serialized) struct PreflightTests {
    @Test func aCopyThatCanNotFitIsRefusedBeforeWritingAnything() async throws {
        let disk = try TestVolume(name: "ScopePreA")
        let small = try TestVolume(name: "ScopePreSmall", sizeMB: 96)
        try small.write("kept.txt", "kept")
        try disk.write("folder/one.bin", Data(repeating: 1, count: 80 * 1024 * 1024))
        try disk.write("folder/two.bin", Data(repeating: 2, count: 80 * 1024 * 1024))
        let ops = OperationHarness(engine: FileEngine(pathGuard: .restricted(to: [disk.mountPoint, small.mountPoint])))

        for kind in [FileOperation.Kind.copy, FileOperation.Kind.move] {
            do {
                try await ops.run(kind([disk.url("folder")], small.work))
                Issue.record("The copy should have been refused")
            } catch let error as OperationError {
                guard case .notEnoughSpace(let needed, let available, _) = error else {
                    Issue.record("Unexpected error: \(error)")
                    continue
                }
                #expect(needed == 160 * 1024 * 1024)
                #expect(available < needed)
                #expect(error.localizedDescription.contains("Nothing was copied"))
            }
            #expect(try small.names() == ["kept.txt"])
            #expect(try disk.names("folder") == ["one.bin", "two.bin"])
        }
    }

    @Test func clonesAndMovesOnOneAPFSDiskNeedNoSpace() async throws {
        let small = try TestVolume(name: "ScopePreClone", sizeMB: 96)
        try small.write("big.bin", Data(repeating: 3, count: 60 * 1024 * 1024))
        try FileManager.default.createDirectory(at: small.url("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: small.url("b"), withIntermediateDirectories: true)
        let ops = OperationHarness(engine: FileEngine(pathGuard: .restricted(to: [small.mountPoint])))

        // Too little room for a second real copy, but a clone takes none.
        try await ops.run(.copy([small.url("big.bin")], into: small.url("a")))
        try await ops.run(.move([small.url("big.bin")], into: small.url("b")))
        #expect(try small.names("a") == ["big.bin"])
        #expect(try small.names("b") == ["big.bin"])
    }

    @Test func aFAT32DiskRefusesFilesOver4GBAndNamesItCanNotStore() async throws {
        let disk = try TestVolume(name: "ScopePreB")
        let fat = try TestVolume(name: "SCOPEFAT", sizeMB: 128, fileSystem: "MS-DOS FAT32")
        let ops = OperationHarness(engine: FileEngine(pathGuard: .restricted(to: [disk.mountPoint, fat.mountPoint])))

        // Sparse, so it takes no room on the test disk.
        let huge = disk.url("huge.bin")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: 4 * 1024 * 1024 * 1024 + 1)
        try handle.close()
        do {
            try await ops.run(.copy([huge], into: fat.work))
            Issue.record("The oversized file should have been refused")
        } catch let OperationError.incompatibleDestination(report) {
            #expect(
                report.entries.contains {
                    $0.path == "huge.bin" && $0.reason == .fileTooLarge(limit: 4 * 1024 * 1024 * 1024 - 1)
                })
        }

        try disk.write("notes/a:b.txt", "colon")
        try disk.write("notes/fine.txt", "fine")
        do {
            try await ops.run(.copy([disk.url("notes")], into: fat.work))
            Issue.record("The incompatible name should have been refused")
        } catch let OperationError.incompatibleDestination(report) {
            #expect(report.entries.contains { $0.path == "notes/a:b.txt" && $0.reason == .invalidName })
        }
        #expect(try fat.names() == [])

        // What FAT can take still copies.
        try await ops.run(.copy([disk.url("notes/fine.txt")], into: fat.work))
        #expect(try fat.read("fine.txt") == "fine")
    }

    @Test func limitsComeFromTheFileSystem() {
        let fat = FileEngine.DestinationLimits(fileSystem: "msdos", volumeName: "USB", freeBytes: 10)
        #expect(fat.maxFileSize == 4 * 1024 * 1024 * 1024 - 1)
        #expect(fat.usesFATNames && !fat.clones)
        let exFAT = FileEngine.DestinationLimits(fileSystem: "exfat", volumeName: "USB", freeBytes: 10)
        #expect(exFAT.maxFileSize == nil && exFAT.usesFATNames)
        let apfs = FileEngine.DestinationLimits(fileSystem: "apfs", volumeName: "Disk", freeBytes: nil)
        #expect(apfs.maxFileSize == nil && !apfs.usesFATNames && apfs.clones)
    }

    @Test(arguments: [
        ("report.txt", true), ("Ünïcode ✓.txt", true), (".hidden", true),
        ("a:b", false), ("a/b", false), ("what?", false), ("star*", false), ("quote\"", false),
        ("less<", false), ("pipe|", false), ("back\\slash", false), ("tab\tname", false),
        ("trailing space ", false), ("trailing dot.", false), ("", false),
        (String(repeating: "x", count: 255), true), (String(repeating: "x", count: 256), false),
    ])
    func fatNameRules(name: String, storable: Bool) {
        #expect(FileEngine.isStorableOnFAT(name) == storable)
    }
}
