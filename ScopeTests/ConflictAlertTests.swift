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
        existingModified: Date(timeIntervalSince1970: 1_700_000_000),
        incomingKind: .file, existingKind: .file)

    @Test func everyButtonHasAnAnswer() {
        let alert = OperationsController.conflictAlert(conflict)
        #expect(alert.buttons.map(\.title) == ["Keep Both", "Replace", "Replace If Older", "Skip", "Stop"])
        #expect(OperationsController.conflictChoices == [.keepBoth, .replace, .replaceIfOlder, .skip, .stop])
        #expect(alert.showsSuppressionButton)
        #expect(alert.suppressionButton?.title == "Apply to all file → file conflicts")
    }

    @Test func namesTheItemAndShowsBothDates() {
        let alert = OperationsController.conflictAlert(conflict)
        #expect(alert.messageText == "An item named “notes.txt” already exists in “docs”.")
        #expect(alert.informativeText.contains("Existing: /Volumes/ScopeTest/docs/notes.txt (file, modified"))
        #expect(alert.informativeText.contains("New: /Volumes/ScopeTest2/notes.txt (file, modified"))
    }

    @Test func replacingAnExistingFolderExplainsTheWholeTree() {
        let mixed = Conflict(
            incoming: conflict.incoming, existing: conflict.existing,
            incomingKind: .symbolicLink, existingKind: .directory)
        let alert = OperationsController.conflictAlert(mixed)
        #expect(alert.informativeText.contains("symbolic link"))
        #expect(alert.informativeText.contains("entire existing folder"))
        #expect(alert.informativeText.contains("including items only in that folder"))
        #expect(alert.informativeText.contains("does not merge folders"))
        #expect(alert.suppressionButton?.title == "Apply to all symbolic link → folder conflicts")
    }

    @Test func eligibleFoldersOfferMergeBeforeOtherChoices() {
        let folders = Conflict(
            incoming: conflict.incoming, existing: conflict.existing,
            incomingKind: .directory, existingKind: .directory, canMerge: true)
        let alert = OperationsController.conflictAlert(folders)
        #expect(alert.buttons.map(\.title) == ["Merge", "Keep Both", "Replace", "Replace If Older", "Skip", "Stop"])
        #expect(
            OperationsController.conflictChoices(for: folders) == [
                .merge, .keepBoth, .replace, .replaceIfOlder, .skip, .stop,
            ])
        #expect(alert.informativeText.contains("Merging combines both folders"))
    }

    @Test func ineligibleFoldersDoNotOfferMerge() {
        let folders = Conflict(
            incoming: conflict.incoming, existing: conflict.existing,
            incomingKind: .directory, existingKind: .directory)
        #expect(
            OperationsController.conflictAlert(folders).buttons.map(\.title) == [
                "Keep Both", "Replace", "Replace If Older", "Skip", "Stop",
            ])
        #expect(OperationsController.conflictChoices(for: folders) == OperationsController.conflictChoices)
    }

    @Test func unknownTypesCannotBeAppliedToAll() {
        let unknown = Conflict(incoming: conflict.incoming, existing: conflict.existing)
        let alert = OperationsController.conflictAlert(unknown)
        #expect(!alert.showsSuppressionButton)
        #expect(alert.informativeText.contains("item of unknown type"))
    }

    @Test func showsAnAvailableDateEvenIfTheOtherIsMissing() {
        let partial = Conflict(
            incoming: conflict.incoming, existing: conflict.existing,
            incomingModified: conflict.incomingModified,
            incomingKind: .file, existingKind: .symbolicLink)
        let alert = OperationsController.conflictAlert(partial)
        #expect(alert.informativeText.contains("symbolic link)"))
        #expect(alert.informativeText.contains("file, modified"))
    }
}
