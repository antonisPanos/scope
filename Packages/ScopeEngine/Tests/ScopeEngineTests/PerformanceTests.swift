import Foundation
import Testing

@testable import ScopeEngine

/// Speed checks against the test disk's folder of 100,000 files. Targets from
/// the scoping doc: a 10,000-item folder lists in under 500 ms. These record
/// timings and fail only far beyond the target, to stay stable on busy machines.
@Suite(.enabled(if: Sandbox.testDiskMounted, "needs the test disk"))
struct PerformanceTests {
    let engine = FileEngine(pathGuard: .restricted(to: [Sandbox.testDisk]))
    let many = Sandbox.testDisk.appendingPathComponent("many")

    @Test func listsAndSortsTheBigFolder() async throws {
        let clock = ContinuousClock()
        var items: [FileItem] = []
        let listing = try await clock.measure {
            items = try await engine.contentsOfDirectory(at: many)
        }
        let sorting = clock.measure { _ = FileSort(key: .name).sorted(items) }
        print("Listed \(items.count) items in \(listing), sorted by name in \(sorting)")
        #expect(items.count >= 100_000)
        // 100,000 items is ten times the target folder size, so allow ten times the time, plus slack.
        #expect(listing < .seconds(10))
        #expect(sorting < .seconds(5))
    }

    @Test func searchesTheWholeTestDisk() async throws {
        let clock = ContinuousClock()
        var found = 0
        var firstResult: Duration?
        let start = clock.now
        for try await batch in try engine.search(SearchQuery(text: "file-0999"), in: Sandbox.testDisk) {
            if firstResult == nil { firstResult = clock.now - start }
            found += batch.count
        }
        let total = clock.now - start
        print("Searched the test disk in \(total), first result after \(firstResult ?? .zero), \(found) found")
        #expect(found == 100)
        #expect(total < .seconds(15))
    }
}
