import AppKit
import Testing

@testable import Scope

@MainActor struct UpdateBannerTests {
    @Test func attachesBelowTheToolbarWithoutChangingFocusAndExposesBothActions() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.toolbar = NSToolbar(identifier: "UpdateBannerTest")
        let field = NSTextField(string: "Focused field")
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let responder = window.firstResponder

        let version = try #require(ReleaseVersion("0.10.0"))
        var opened: URL?
        var dismissed = false
        let banner = UpdateBannerController(version: version, openRelease: { opened = $0 }) { dismissed = true }
        window.addTitlebarAccessoryViewController(banner)
        #expect(banner.layoutAttribute == .bottom)
        #expect(window.firstResponder === responder)
        let row = try #require(banner.view.subviews.first as? NSStackView)
        let label = try #require(row.arrangedSubviews.first as? NSTextField)
        #expect(label.stringValue == "Scope 0.10.0 is available.")
        let buttons = row.arrangedSubviews.compactMap { $0 as? NSButton }
        let release = try #require(buttons.first { $0.title == "View Release" })
        let dismiss = try #require(buttons.first { $0.title == "Dismiss" })
        #expect(window.makeFirstResponder(release))
        #expect(window.firstResponder === release)
        release.performClick(nil)
        #expect(opened == version.releasePage)
        #expect(window.makeFirstResponder(dismiss))
        #expect(window.firstResponder === dismiss)
        dismiss.performClick(nil)
        #expect(dismissed)
    }
}
