import Foundation
import ScopeEngine
import Testing

@testable import Scope

/// The window that started an operation selects what it made or renamed.
/// Following announced changes in a tab is checked by hand on the test disk:
/// app tests don't write files of their own.
@MainActor struct AnnouncedChangesTests {
    @Test func whichOperationsSelectTheirResult() {
        let file = URL(fileURLWithPath: "/Volumes/ScopeTest/a.txt")
        let folder = URL(fileURLWithPath: "/Volumes/ScopeTest/b")
        #expect(BrowserWindowController.selectsResult(.copy([file], into: folder)))
        #expect(BrowserWindowController.selectsResult(.move([file], into: folder)))
        #expect(BrowserWindowController.selectsResult(.duplicate([file])))
        #expect(BrowserWindowController.selectsResult(.rename(file, to: "c.txt")))
        #expect(BrowserWindowController.selectsResult(.newFolder(in: folder, name: "new")))
        #expect(BrowserWindowController.selectsResult(.extract(file)))
        #expect(!BrowserWindowController.selectsResult(.trash([file])))
        #expect(!BrowserWindowController.selectsResult(.undo(UndoRecord(title: "x"))))
        #expect(!BrowserWindowController.selectsResult(.ejectVolume(folder)))
    }
}
