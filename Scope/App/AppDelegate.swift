import AppKit
import os

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var browsers: [ObjectIdentifier: BrowserWindowController] = [:]
    private static let logger = Logger(subsystem: "com.antonispanos.scope", category: "App")

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    /// True when Scope Dev runs as the host of the app's unit tests. It then
    /// opens no window and watches nothing, so the tests start from a quiet app.
    static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        guard !Self.isHostingTests else {
            Self.logger.notice("Hosting unit tests; no window opened")
            return
        }
        NSWindow.allowsAutomaticWindowTabbing = true
        SidebarStore.shared.start()
        _ = SystemNotifier.shared  // becomes the notification delegate before any click arrives
        #if SCOPE_DEV
        DevHooks.install()
        #endif
        let identity = BuildIdentity.current
        Self.logger.notice(
            "Launched \(identity.appName, privacy: .public): sandbox \(identity.isSandboxed), writes \(identity.pathGuard.allowsWrites)"
        )
        newWindow(nil)
    }

    /// Closing the last window quits Scope, except while jobs run: then it
    /// stays in the Dock and quits once they finish (a Dock click brings a
    /// window back and cancels that).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // A UI test may close its last temporary window while other tests run.
        guard !Self.isHostingTests else { return false }
        let operations = OperationsController.shared
        guard operations.active.isEmpty else {
            operations.quitWhenIdle = true
            Self.logger.notice("Last window closed while jobs run; quitting when they finish")
            return false
        }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            OperationsController.shared.quitWhenIdle = false
            newWindow(nil)
        }
        return true
    }

    /// Cmd+Q, logout or shutdown while jobs run: ask first, so a copy is
    /// never cut short by accident.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let operations = OperationsController.shared
        let running = operations.active.count
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running == 1 ? "A job is still running." : "\(running) jobs are still running."
        alert.informativeText =
            "Quit When Done keeps Scope in the Dock until they finish. Quit Now cancels them; finished items stay, unfinished copies are removed."
        alert.addButton(withTitle: "Quit When Done")
        alert.addButton(withTitle: "Quit Now")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            operations.quitWhenIdle = true
            for window in NSApp.windows where window.isVisible || window.windowController is BrowserWindowController {
                window.close()
            }
            return .terminateCancel
        case .alertSecondButtonReturn:
            operations.quitWhenIdle = false
            operations.cancelAll()
            Task { @MainActor in
                // Cancelling never hangs, but don't wait forever either.
                let deadline = Date().addingTimeInterval(5)
                while !OperationsController.shared.active.isEmpty, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        default:
            return .terminateCancel
        }
    }

    /// From a notification: bring a browser window forward with its activity drawer open.
    func showActivityInFrontWindow() {
        let existing = NSApp.orderedWindows.lazy.compactMap { $0.windowController as? BrowserWindowController }.first
        if existing == nil { newWindow(nil) }
        guard
            let controller = existing
                ?? NSApp.orderedWindows.lazy.compactMap({ $0.windowController as? BrowserWindowController }).first
        else { return }
        OperationsController.shared.quitWhenIdle = false
        controller.window?.makeKeyAndOrderFront(nil)
        controller.showActivity(true)
    }

    /// Creates a browser tab; the caller decides where its window goes.
    func makeBrowser(location: Location) -> BrowserWindowController {
        let controller = BrowserWindowController(location: location)
        controller.onClose = { [weak self] closed in
            self?.browsers[ObjectIdentifier(closed)] = nil
        }
        browsers[ObjectIdentifier(controller)] = controller
        return controller
    }

    @objc func showSettings(_ sender: Any?) {
        if SettingsWindowController.shared.window?.isVisible != true {
            SettingsWindowController.shared.window?.layoutIfNeeded()
            SettingsWindowController.shared.window?.center()
        }
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = makeBrowser(location: .folder(BuildIdentity.current.startFolder))
        guard let window = controller.window else { return }
        // A new window opens as its own window, not as a tab of the current one.
        window.tabbingMode = .disallowed
        if browsers.count == 1 {
            window.setFrameAutosaveName("BrowserWindow")
            if window.frame.origin == .zero { window.center() }
        } else if let key = NSApp.keyWindow {
            window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 24, y: key.frame.maxY - 24))
        }
        controller.showWindow(nil)
        window.tabbingMode = .preferred
        controller.focusFileList()
    }
}
