import AppKit
import Testing

@testable import Scope

/// The question asked before an undo trashes files edited since.
@MainActor
struct UndoChangedAlertTests {
    @Test func namesTheFileAndKeepsCancelOnEscape() {
        let alert = OperationsController.changedSinceAlert([URL(fileURLWithPath: "/Volumes/ScopeTest/notes.txt")])
        #expect(alert.messageText.contains("“notes.txt” was changed after it was made"))
        #expect(alert.buttons.map(\.title) == ["Undo Anyway", "Cancel"])
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
    }

    @Test func listsSeveralFiles() {
        let items = (1...12).map { URL(fileURLWithPath: "/Volumes/ScopeTest/f\($0).txt") }
        let alert = OperationsController.changedSinceAlert(items)
        #expect(alert.messageText.hasPrefix("12 items"))
        #expect(alert.informativeText.contains("• f1.txt\n• f2.txt"))
        #expect(alert.informativeText.hasSuffix("…and 2 more"))
    }
}
