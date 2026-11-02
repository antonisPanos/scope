import Foundation
import Testing

@testable import ScopeEngine

/// Adding and removing a Finder tag on files and folders.
@Suite(.serialized) struct TaggingTests {
    let disk: TestVolume
    let engine: FileEngine

    init() throws {
        disk = try TestVolume(name: "ScopeTagging")
        engine = FileEngine(pathGuard: .restricted(to: [disk.mountPoint]))
    }

    private func tags(_ name: String) throws -> [String] {
        try disk.url(name).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    @Test func tagsFoldersAndFilesAndKeepsOtherTags() async throws {
        try disk.write("folder/inside.txt", "x")
        try disk.write("file.txt", "y")
        try (disk.url("file.txt") as NSURL).setResourceValue(["Work"], forKey: .tagNamesKey)
        let ops = OperationHarness(engine: engine)

        try await ops.run(.setTag([disk.url("folder"), disk.url("file.txt")], tag: "Red", applied: true))
        #expect(try tags("folder") == ["Red"])
        #expect(try tags("file.txt") == ["Work", "Red"])
        // The folder's contents are left alone.
        #expect(try tags("folder/inside.txt") == [])

        // Applying it again adds no second copy.
        try await ops.run(.setTag([disk.url("folder")], tag: "Red", applied: true))
        #expect(try tags("folder") == ["Red"])

        try await ops.run(.setTag([disk.url("folder"), disk.url("file.txt")], tag: "Red", applied: false))
        #expect(try tags("folder") == [])
        #expect(try tags("file.txt") == ["Work"])
        #expect(try await engine.tags(for: disk.url("file.txt")) == ["Work"])
    }

    @Test func refusesPlacesOutsideTheGuard() async throws {
        let other = try TestVolume(name: "ScopeTaggingOther")
        try other.write("a.txt", "a")
        let ops = OperationHarness(engine: engine)
        await #expect(throws: (any Error).self) {
            try await ops.run(.setTag([other.url("a.txt")], tag: "Red", applied: true))
        }
        #expect(try other.url("a.txt").resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [] == [])
    }

    @Test(arguments: [false, true], [false, true])
    func tagsTheLinkWithoutChangingItsOutsideTarget(directory: Bool, applied: Bool) async throws {
        let outside = try disk.write("outside/sentinel.txt", "untouched")
        let target = directory ? outside.deletingLastPathComponent() : outside
        try (target as NSURL).setResourceValue(["Red", "Work"], forKey: .tagNamesKey)
        try disk.write("allowed/placeholder", "fixture")
        let link = disk.url("allowed/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let before = try TreeSnapshot(disk.url("outside"))
        let engine = FileEngine(pathGuard: .writesOnlyUnder([disk.url("allowed")]))
        let ops = OperationHarness(engine: engine)
        if !applied { try await ops.run(.setTag([link], tag: "Red", applied: true)) }
        try await ops.run(.setTag([link], tag: "Red", applied: applied))
        #expect(try await engine.tags(for: link) == (applied ? ["Red"] : []))
        #expect(try TreeSnapshot(disk.url("outside")) == before)
    }

    @Test func anOpenedTagItemCannotBeRedirectedByReplacingItsPath() throws {
        let selected = try disk.write("allowed/selected.txt", "selected")
        let outside = try disk.write("outside/sentinel.txt", "untouched")
        let guardPolicy = PathGuard.writesOnlyUnder([disk.url("allowed")])
        let location = try CopyLocation(checked: guardPolicy.checkWriteLocation(selected))
        let descriptor = try FinderTags.open(location)
        let saved = disk.url("allowed/saved.txt")
        try FileManager.default.moveItem(at: selected, to: saved)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: outside)
        let before = try TreeSnapshot(disk.url("outside"))
        try FinderTags.write([FinderTags.encode("Red")], to: descriptor, path: selected.path)
        #expect(try saved.resourceValues(forKeys: [.tagNamesKey]).tagNames == ["Red"])
        #expect(try TreeSnapshot(disk.url("outside")) == before)
    }

    @Test func colorTagsMatchFoundationAndKeepExistingTagColors() async throws {
        let file = try disk.write("tagged.txt", "fixture")
        let reference = try disk.write("foundation.txt", "fixture")
        try (file as NSURL).setResourceValue(["Blue", "Work"], forKey: .tagNamesKey)
        try (reference as NSURL).setResourceValue(["Blue", "Work", "Red"], forKey: .tagNamesKey)
        try await OperationHarness(engine: engine).run(.setTag([file], tag: "Red", applied: true))
        #expect(try tags("tagged.txt") == ["Blue", "Work", "Red"])
        #expect(
            try file.resourceValues(forKeys: [.labelNumberKey]).labelNumber
                == reference.resourceValues(forKeys: [.labelNumberKey]).labelNumber)
        let stored = try FinderTags.read(FinderTags.open(CopyLocation(checked: file)), path: file.path)
        #expect(stored.contains("Blue\n4"))
        #expect(stored.contains("Red\n6"))
        try await OperationHarness(engine: engine).run(.setTag([file], tag: "Red", applied: false))
        #expect(try URL(fileURLWithPath: file.path).resourceValues(forKeys: [.labelNumberKey]).labelNumber == 4)
        try await OperationHarness(engine: engine).run(.setTag([file], tag: "Blue", applied: false))
        #expect(try URL(fileURLWithPath: file.path).resourceValues(forKeys: [.labelNumberKey]).labelNumber == 0)
        #expect(try await engine.tags(for: file) == ["Work"])
    }

    @Test func readingLegacyLabelsMatchesFoundation() async throws {
        let file = try disk.write("legacy.txt", "fixture")
        for number in 0...7 {
            try (file as NSURL).setResourceValue(number, forKey: .labelNumberKey)
            let expected = try URL(fileURLWithPath: file.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
            let actual = try await engine.tags(for: file)
            #expect(actual == expected)
        }
        let ops = OperationHarness(engine: engine)
        try await ops.run(.setTag([file], tag: "Work", applied: true))
        #expect(try await engine.tags(for: file) == ["Orange", "Work"])
        try await ops.run(.setTag([file], tag: "Orange", applied: false))
        #expect(try await engine.tags(for: file) == ["Work"])
    }

    @Test func coloringKeepsUnrelatedFinderFlags() async throws {
        let file = try disk.write("flagged.txt", "fixture")
        var finder = [UInt8](repeating: 0, count: 32)
        finder[0] = 0x54
        finder[8] = 0x40
        finder[9] = 0x01
        #expect(setxattr(file.path, "com.apple.FinderInfo", finder, finder.count, 0, 0) == 0)
        try await OperationHarness(engine: engine).run(.setTag([file], tag: "Red", applied: true))
        var actual = [UInt8](repeating: 0, count: 32)
        #expect(getxattr(file.path, "com.apple.FinderInfo", &actual, actual.count, 0, 0) == 32)
        finder[9] |= 6 << 1
        #expect(actual == finder)
    }
}
