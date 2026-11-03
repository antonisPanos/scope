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

    /// The text of the list of items in the alert's accessory box.
    private func list(in alert: NSAlert) -> String? {
        ((alert.accessoryView as? NSScrollView)?.documentView as? NSTextView)?.string
    }

    @Test func namesTheDiskAndEveryItem() {
        let alert = OperationsController.permanentDeletionAlert(request(2))
        #expect(alert.messageText.contains("“Share” has no Trash"))
        #expect(list(in: alert) == "• item 1.txt — in /Volumes/Share\n• item 2.txt — in /Volumes/Share")
        #expect(alert.informativeText.contains("can't be undone"))
        let one = OperationsController.permanentDeletionAlert(request(1))
        #expect(one.messageText.contains("Delete “item 1.txt” for good?"))
    }

    @Test func deleteImmediatelyAsksTheSameWay() {
        let items = [URL(fileURLWithPath: "/Volumes/extsd/a.txt"), URL(fileURLWithPath: "/Volumes/extsd/b")]
        let alert = OperationsController.permanentDeletionAlert(
            PermanentDeletion(items: items, volume: "extsd", reason: .requested))
        #expect(alert.messageText == "Delete these 2 items on “extsd” immediately?")
        #expect(list(in: alert) == "• a.txt — in /Volumes/extsd\n• b — in /Volumes/extsd")
        #expect(alert.buttons.map(\.title) == ["Cancel", "Delete Permanently"])
        #expect(alert.buttons[0].keyEquivalent == "\r")
    }

    /// More than ten items, and two with the same name in different
    /// folders (as Search or Recents can select): every one is listed with
    /// its folder, for both reasons, and the safe buttons stay the same.
    @Test(arguments: [PermanentDeletion.Reason.noTrash, .requested])
    func everyItemIsListedWithItsFolder(reason: PermanentDeletion.Reason) throws {
        let items =
            (1...11).map { URL(fileURLWithPath: "/Volumes/Share/item \($0).txt") } + [
                URL(fileURLWithPath: "/Volumes/Share/first/same.txt"),
                URL(fileURLWithPath: "/Volumes/Share/second/same.txt"),
            ]
        let alert = OperationsController.permanentDeletionAlert(
            PermanentDeletion(items: items, volume: "Share", reason: reason))
        let text = try #require(list(in: alert))
        let lines = text.components(separatedBy: "\n")
        #expect(lines.count == items.count)
        for item in items {
            #expect(lines.contains("• \(item.lastPathComponent) — in \(item.deletingLastPathComponent().path)"))
        }
        #expect(!text.contains("more"))
        #expect(alert.messageText.contains("13 items"))
        #expect(alert.buttons.map(\.title) == ["Cancel", "Delete Permanently"])
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(!alert.showsSuppressionButton)
    }

    /// The short listing is only for questions that delete nothing.
    @Test func longListsAreCut() {
        let text = OperationsController.listing(request(13).items)
        #expect(text.components(separatedBy: "\n").count == 11)
        #expect(text.hasSuffix("…and 3 more"))
    }
}
