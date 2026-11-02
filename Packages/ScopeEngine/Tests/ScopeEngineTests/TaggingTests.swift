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
}
