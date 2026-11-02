import Foundation
import ScopeEngine
import Testing

@testable import Scope

@MainActor struct NestedFolderListingTests {
    @Test func nestedListingsResortAndReleaseTheirSubscription() async throws {
        // Only repository source metadata is read; app tests create no files.
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let missing = folder.appendingPathComponent("missing-" + UUID().uuidString)
        let model = BrowserModel(engine: FileEngine(pathGuard: .readOnly), location: .folder(missing))
        defer { model.close() }
        var snapshots: [[FileItem]] = []
        var listing: NestedFolderListing? = NestedFolderListing(url: folder, model: model) { snapshots.append($0) }
        weak var weakListing = listing
        for _ in 0..<500 {
            if snapshots.last?.isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(snapshots.last?.isEmpty == false)
        let descending = FileSort(key: .name, ascending: false)
        listing?.update(sort: descending, showHidden: true)
        for _ in 0..<500 {
            if let last = snapshots.last, !last.isEmpty, last == descending.sorted(last) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let last = try #require(snapshots.last)
        #expect(last == descending.sorted(last))
        listing = nil
        #expect(weakListing == nil)
        let count = snapshots.count
        try await Task.sleep(for: .milliseconds(30))
        #expect(snapshots.count == count)
    }
}
