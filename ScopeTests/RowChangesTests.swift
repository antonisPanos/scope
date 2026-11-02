import Foundation
import ScopeEngine
import Testing

@testable import Scope

/// Turning a list's rows into the new rows from row changes, as the list and
/// icon views do when a folder changes on disk.
struct RowChangesTests {
    /// The changes FolderListing.rowChanges reports, worked out the same way
    /// for plain strings.
    private func changes(from old: [String], to new: [String]) -> FolderListing.RowChanges {
        var changes = FolderListing.RowChanges()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): changes.removed.insert(offset)
            case .insert(let offset, _, _): changes.inserted.insert(offset)
            }
        }
        return changes
    }

    private func apply(_ old: [String], _ new: [String]) -> [String]? {
        changes(from: old, to: new).applied(to: old, newCount: new.count) { new[$0] }
    }

    @Test func removesAndInsertsInPlace() {
        #expect(apply(["a", "b", "c"], ["a", "c"]) == ["a", "c"])
        #expect(apply(["a", "c"], ["a", "b", "c", "d"]) == ["a", "b", "c", "d"])
        #expect(apply(["a", "b", "c"], ["c", "x", "a"]) == ["c", "x", "a"])
        #expect(apply([], ["a"]) == ["a"])
        #expect(apply(["a"], []) == [])
    }

    @Test func keepsRowsThatOnlyRedraw() {
        // The row object stays: an expanded folder keeps its children.
        let changes = FolderListing.RowChanges(reloaded: [1])
        #expect(changes.applied(to: ["a", "b"], newCount: 2) { _ in "new" } == ["a", "b"])
    }

    @Test func refusesChangesThatDontFit() {
        // Counts that don't add up, or indexes past the end, mean a full reload.
        #expect(FolderListing.RowChanges(removed: [0]).applied(to: ["a"], newCount: 1) { _ in "x" } == nil)
        #expect(
            FolderListing.RowChanges(removed: [3], inserted: [0]).applied(to: ["a"], newCount: 1) { _ in "x" } == nil)
        #expect(FolderListing.RowChanges(inserted: [5]).applied(to: ["a"], newCount: 2) { _ in "x" } == nil)
        #expect(FolderListing.RowChanges(reloaded: [2]).applied(to: ["a"], newCount: 1) { _ in "x" } == nil)
    }

    @Test func matchesTheNewRowsForManyEdits() {
        var random = SystemRandomNumberGenerator()
        let names = (0..<30).map { "item \($0)" }
        for _ in 0..<500 {
            let old = names.filter { _ in Bool.random(using: &random) }.shuffled(using: &random)
            let new = names.filter { _ in Bool.random(using: &random) }.shuffled(using: &random)
            #expect(apply(old, new) == new, "\(old) to \(new)")
        }
    }
}
