import AppKit
import Foundation
import Testing

@testable import Scope

@MainActor struct TagSelectionTests {
    @Test func aMissingTagAfterTheFirst200ItemsAddsItToTheSelection() async throws {
        let urls = fixtures()
        let common = try await TagSelection.commonTags(in: urls) { url in
            url == urls.last ? [] : ["Red"]
        }
        #expect(common.isEmpty)
        #expect(try clickRed(applied: common))
    }

    @Test func aTagOnEveryItemInALargeSelectionIsRemoved() async throws {
        let common = try await TagSelection.commonTags(in: fixtures()) { _ in ["Red", "Work"] }
        #expect(common == ["Red", "Work"])
        #expect(try !clickRed(applied: common))
    }

    @Test func unreadableItemsCannotAuthorizeRemovingATag() async throws {
        let urls = fixtures()
        let common = try await TagSelection.commonTags(in: urls) { url in
            if url == urls.last { throw CocoaError(.fileReadNoPermission) }
            return ["Red"]
        }
        #expect(common.isEmpty)
    }

    @Test func tagsCannotBeToggledBeforeTheSelectionStateLoads() throws {
        var called = false
        let row = TagMenuView { _, _ in called = true }
        let red = try redButton(in: row)
        #expect(!red.isEnabled)
        red.performClick(nil)
        #expect(!called)
    }

    private func fixtures() -> [URL] {
        // These names are only inputs to the injected reader; no disk access.
        (0..<201).map { URL(fileURLWithPath: "/tag-selection-fixture/\($0)") }
    }

    private func clickRed(applied: Set<String>) throws -> Bool {
        var result: Bool?
        let row = TagMenuView { tag, add in
            #expect(tag == "Red")
            result = add
        }
        row.showApplied(applied)
        let red = try redButton(in: row)
        #expect(red.isEnabled)
        red.performClick(nil)
        return try #require(result)
    }

    private func redButton(in row: TagMenuView) throws -> TagButton {
        let stack = try #require(row.subviews.first as? NSStackView)
        return try #require(stack.arrangedSubviews.compactMap { $0 as? TagButton }.first { $0.tagName == "Red" })
    }
}
