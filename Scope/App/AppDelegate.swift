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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        NSWindow.allowsAutomaticWindowTabbing = true
        SidebarStore.shared.start()
        #if SCOPE_DEV
        DevHooks.install()
        #endif
        let identity = BuildIdentity.current
        Self.logger.notice("Launched \(identity.appName, privacy: .public): sandbox \(identity.isSandboxed), writes \(identity.pathGuard.allowsWrites)")
        newWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
