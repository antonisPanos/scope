import AppKit
import ScopeEngine
import Testing

@testable import Scope

/// The question asked when an item can't be copied or moved.
@MainActor
struct FailureAlertTests {
    @Test func offersTryAgainSkipAndStop() {
        let failure = ItemFailure(
            item: URL(fileURLWithPath: "/Volumes/ScopeTest/photo.jpg"), message: "The disk couldn't be read.")
        let alert = OperationsController.failureAlert(failure)
        #expect(alert.messageText == "“photo.jpg” couldn't be copied.")
        #expect(alert.informativeText.hasPrefix("The disk couldn't be read."))
        #expect(alert.buttons.map(\.title) == ["Try Again", "Skip", "Stop"])
        #expect(alert.suppressionButton?.title == "Skip all failures")
    }
}
