import AppKit
import ScopeEngine
import Testing

@testable import Scope

/// The tests run inside Scope Dev, which must stay the guarded development
/// build while they do: it reads anywhere but changes only the scratch folder.
@MainActor
struct TestHostTests {
    @Test func theHostIsTheDevelopmentBuild() {
        let identity = BuildIdentity.current
        #expect(identity.isDevelopment)
        #expect(AppDelegate.isHostingTests)
    }

    @Test func theGuardChangesOnlyTheScratchFolder() throws {
        let pathGuard = BuildIdentity.current.pathGuard
        // Only asks the guard; nothing is written.
        #expect(pathGuard.permits(BuildIdentity.realHome))
        for url in [
            BuildIdentity.realHome, BuildIdentity.realHome.appendingPathComponent("Documents/new.txt"),
            URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/tmp/new.txt"),
        ] {
            #expect(throws: PathGuardViolation.self, "\(url.path)") { try pathGuard.checkWriteLocation(url) }
        }
        let inside = BuildIdentity.scratchFolder.appendingPathComponent("new.txt")
        #expect(try pathGuard.checkWriteLocation(inside).lastPathComponent == "new.txt")
        #expect(throws: PathGuardViolation.self) { try pathGuard.checkModifiable(BuildIdentity.scratchFolder) }
    }

    @Test func theHostOpensNoWindow() {
        #expect(!NSApp.windows.contains { $0.windowController is BrowserWindowController })
    }

    @Test func closingATestWindowDoesNotQuitTheHost() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }
}
