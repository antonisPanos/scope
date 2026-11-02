import AppKit
import Testing

@testable import Scope

/// The tests run inside Scope Dev, which must stay the sandboxed, guarded
/// development build while they do.
@MainActor
struct TestHostTests {
    @Test func theHostIsTheDevelopmentBuild() {
        let identity = BuildIdentity.current
        #expect(identity.isDevelopment)
        #expect(AppDelegate.isHostingTests)
    }

    @Test func theGuardRefusesTheHomeFolder() {
        let pathGuard = BuildIdentity.current.pathGuard
        #expect(!pathGuard.permits(BuildIdentity.realHome))
        #expect(!pathGuard.permits(URL(fileURLWithPath: "/")))
    }

    @Test func theHostOpensNoWindow() {
        #expect(!NSApp.windows.contains { $0.windowController is BrowserWindowController })
    }
}
