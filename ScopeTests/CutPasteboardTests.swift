import AppKit
import Testing

@testable import Scope

@MainActor struct CutPasteboardTests {
    @Test func cutsReplaceEarlierPathsAndMatchOnlyStandardizedEntries() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let cut = CutPasteboard(pasteboard: pasteboard)
        let folder = TestPaths.packages
        cut.write([folder], cut: true)
        #expect(cut.isCut)
        #expect(cut.contains(URL(fileURLWithPath: folder.path + "/")))
        #expect(cut.contains(folder.appendingPathComponent("Other/..")))
        #expect(!cut.contains(URL(fileURLWithPath: folder.path.lowercased())))
        #expect(!cut.contains(folder.appendingPathComponent("child.txt")))
        #expect(!cut.contains(URL(fileURLWithPath: "/elsewhere/Folder")))
        let replacement = folder.appendingPathComponent("ScopeEngine/Package.swift")
        cut.write([replacement], cut: true)
        #expect(!cut.contains(folder))
        #expect(cut.contains(replacement))
    }

    @Test func emptySelectionPreservesCutAndConsumptionLeavesClipboardIntact() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let cut = CutPasteboard(pasteboard: pasteboard)
        let file = URL(fileURLWithPath: #filePath)
        cut.write([file], cut: true)
        let generation = pasteboard.changeCount
        cut.write([])
        cut.write([], cut: true)
        #expect(cut.contains(file))
        #expect(pasteboard.changeCount == generation)
        cut.invalidate()
        #expect(!cut.isCut)
        #expect(!cut.contains(file))
        #expect(pasteboard.changeCount == generation)
        #expect(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] == [file])
        cut.validate()
        #expect(!cut.isCut)
    }

    @Test func copyAndExternalClipboardChangesClearCut() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let cut = CutPasteboard(pasteboard: pasteboard)
        let file = URL(fileURLWithPath: #filePath)
        cut.write([file], cut: true)
        cut.write([file])
        #expect(!cut.isCut)
        cut.write([file], cut: true)
        pasteboard.clearContents()
        pasteboard.setString("Something copied elsewhere", forType: .string)
        // Reads must validate even before the polling timer gets a turn.
        #expect(!cut.contains(file))
        #expect(!cut.isCut)
        cut.write([file], cut: true)
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        #expect(!cut.isCut)
    }

    @Test func pollingAndActivationNotifyWithoutAConsumerReadingTheState() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let cut = CutPasteboard(pasteboard: pasteboard)
        let file = URL(fileURLWithPath: #filePath)
        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: CutPasteboard.didChange, object: cut, queue: .main
        ) { _ in
            MainActor.assumeIsolated { changes += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        cut.write([file], cut: true)
        #expect(changes == 1)
        pasteboard.clearContents()
        for _ in 0..<100 where changes < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes == 2)
        cut.write([file], cut: true)
        pasteboard.clearContents()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(changes == 4)
        cut.invalidate()
        #expect(changes == 4)
    }
}
