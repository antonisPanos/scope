import AppKit
import ScopeEngine
import Testing

@testable import Scope

/// The question asked before deleting for good on a disk with no Trash.
@MainActor
struct PermanentDeletionAlertTests {
    private func request(_ count: Int) -> PermanentDeletion {
        let items = (1...count).map { URL(fileURLWithPath: "/Volumes/Share/item \($0).txt") }
        return PermanentDeletion(items: items, volume: "Share")
    }

    @Test func cancelIsTheDefaultAndThereIsNoApplyToAll() {
        let alert = OperationsController.permanentDeletionAlert(request(2))
        #expect(alert.buttons.map(\.title) == ["Cancel", "Delete Permanently"])
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].keyEquivalent == "")
        #expect(alert.buttons[1].hasDestructiveAction)
        #expect(!alert.showsSuppressionButton)
        #expect(alert.alertStyle == .critical)
    }

    @Test func namesTheDiskAndEveryItem() {
        let alert = OperationsController.permanentDeletionAlert(request(2))
        #expect(alert.messageText.contains("“Share” has no Trash"))
        #expect(alert.informativeText.contains("• item 1.txt\n• item 2.txt"))
        #expect(alert.informativeText.contains("can't be undone"))
        let one = OperationsController.permanentDeletionAlert(request(1))
        #expect(one.messageText.contains("Delete “item 1.txt” for good?"))
    }

    @Test func deleteImmediatelyAsksTheSameWay() {
        let items = [URL(fileURLWithPath: "/Volumes/extsd/a.txt"), URL(fileURLWithPath: "/Volumes/extsd/b")]
        let alert = OperationsController.permanentDeletionAlert(
            PermanentDeletion(items: items, volume: "extsd", reason: .requested))
        #expect(alert.messageText == "Delete these 2 items on “extsd” immediately?")
        #expect(alert.informativeText.contains("• a.txt\n• b"))
        #expect(alert.buttons.map(\.title) == ["Cancel", "Delete Permanently"])
        #expect(alert.buttons[0].keyEquivalent == "\r")
    }

    @Test func longListsAreCut() {
        let text = OperationsController.listing(request(13).items)
        #expect(text.components(separatedBy: "\n").count == 11)
        #expect(text.hasSuffix("…and 3 more"))
    }
}
