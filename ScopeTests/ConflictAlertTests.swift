import AppKit
import ScopeEngine
import Testing

@testable import Scope

/// The question asked when an item with the same name already exists.
@MainActor
struct ConflictAlertTests {
    private let conflict = Conflict(
        incoming: URL(fileURLWithPath: "/Volumes/ScopeTest2/notes.txt"),
        existing: URL(fileURLWithPath: "/Volumes/ScopeTest/docs/notes.txt"),
        incomingModified: Date(timeIntervalSince1970: 1_800_000_000),
        existingModified: Date(timeIntervalSince1970: 1_700_000_000))

    @Test func everyButtonHasAnAnswer() {
        let alert = OperationsController.conflictAlert(conflict)
        #expect(alert.buttons.map(\.title) == ["Keep Both", "Replace", "Replace If Older", "Skip", "Stop"])
        #expect(OperationsController.conflictChoices == [.keepBoth, .replace, .replaceIfOlder, .skip, .stop])
        #expect(alert.showsSuppressionButton)
    }

    @Test func namesTheItemAndShowsBothDates() {
        let alert = OperationsController.conflictAlert(conflict)
        #expect(alert.messageText == "An item named “notes.txt” already exists in “docs”.")
        #expect(alert.informativeText.contains("Existing: modified"))
        #expect(alert.informativeText.contains("New: modified"))
    }
}
