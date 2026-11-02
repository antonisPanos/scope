import Foundation
import Testing

@testable import ScopeEngine

/// Listing a folder in batches as it is read.
@Suite struct ListingTests {
    let sandbox: Sandbox

    init() throws {
        sandbox = try Sandbox()
    }

    @Test func batchesAddUpToTheWholeFolder() async throws {
        for index in 0..<1_000 { try sandbox.write(String(format: "big/file %04d.txt", index), "x") }
        try sandbox.write("big/.hidden", "h")
        try sandbox.write("big/sub/deep.txt", "not listed")

        var batches: [[FileItem]] = []
        let listing = try sandbox.engine.listing(of: sandbox.url("big"), batchSize: 200, interval: .seconds(60))
        for try await batch in listing {
            batches.append(batch)
        }
        #expect(batches.allSatisfy { !$0.isEmpty && $0.count <= 200 })
        #expect(batches.count >= 5)
        let streamed = batches.flatMap { $0 }
        let whole = try await sandbox.engine.contentsOfDirectory(at: sandbox.url("big"))
        #expect(Set(streamed) == Set(whole))
        #expect(streamed.count == 1_002)
    }

    @Test func leavesOutHiddenItemsWhenAsked() async throws {
        try sandbox.write("folder/a.txt", "a")
        try sandbox.write("folder/.hidden", "h")
        var names: [String] = []
        for try await batch in try sandbox.engine.listing(of: sandbox.url("folder"), includeHidden: false) {
            names += batch.map(\.name)
        }
        #expect(names == ["a.txt"])
    }

    @Test func anEmptyFolderEndsWithNoBatch() async throws {
        try sandbox.mkdir("empty")
        var count = 0
        for try await _ in try sandbox.engine.listing(of: sandbox.url("empty")) { count += 1 }
        #expect(count == 0)
    }

    @Test func aMissingFolderFails() async throws {
        let stream = try sandbox.engine.listing(of: sandbox.url("missing"))
        await #expect(throws: (any Error).self) {
            for try await _ in stream {}
        }
    }

    @Test func refusesFoldersOutsideTheGuard() throws {
        #expect(throws: PathGuardViolation.self) {
            _ = try sandbox.engine.listing(of: URL(fileURLWithPath: "/etc"))
        }
    }

    @Test func stopsWhenTheConsumerStops() async throws {
        for index in 0..<500 { try sandbox.write("many/\(index)", "x") }
        var first: [FileItem] = []
        let listing = try sandbox.engine.listing(of: sandbox.url("many"), batchSize: 10, interval: .seconds(60))
        for try await batch in listing {
            first = batch
            break
        }
        #expect(first.count == 10)
    }
}
