import Foundation
import Testing
@testable import PandoraEngine

@Suite struct PathGuardTests {
    let sandbox: Sandbox
    let allowed: URL
    let outside: URL
    let pathGuard: PathGuard

    init() throws {
        sandbox = try Sandbox()
        try sandbox.mkdir("allowed")
        try sandbox.mkdir("outside")
        allowed = sandbox.url("allowed")
        outside = sandbox.url("outside")
        pathGuard = .restricted(to: [allowed])
    }

    @Test func allowsTheRootAndItemsInside() throws {
        try sandbox.write("allowed/a.txt", "a")
        #expect(try pathGuard.checkLocation(allowed) == allowed)
        #expect(try pathGuard.checkLocation(allowed.appendingPathComponent("a.txt")).path == allowed.path + "/a.txt")
        #expect(try pathGuard.checkTarget(allowed.appendingPathComponent("a.txt")).path == allowed.path + "/a.txt")
    }

    @Test func allowsItemsThatDoNotExistYet() throws {
        let deep = allowed.appendingPathComponent("new/deeper/file.txt")
        #expect(try pathGuard.checkLocation(deep).path == allowed.path + "/new/deeper/file.txt")
    }

    @Test func refusesPathsOutside() {
        #expect(throws: PathGuardViolation.self) { try pathGuard.checkLocation(outside) }
        #expect(throws: PathGuardViolation.self) { try pathGuard.checkLocation(URL(fileURLWithPath: "/Users")) }
        #expect(throws: PathGuardViolation.self) { try pathGuard.checkLocation(URL(fileURLWithPath: "/")) }
    }

    @Test func refusesASiblingThatSharesThePrefix() throws {
        try sandbox.mkdir("allowed-not-really")
        #expect(throws: PathGuardViolation.self) { try pathGuard.checkLocation(sandbox.url("allowed-not-really")) }
    }

    @Test func refusesParentReferences() {
        let escape = URL(fileURLWithPath: allowed.path + "/../outside")
        let error = #expect(throws: PathGuardViolation.self) { try pathGuard.checkLocation(escape) }
        #expect(error?.reason == .parentReference)
        // Even when the result would land inside again.
        let roundTrip = URL(fileURLWithPath: allowed.path + "/../allowed/x")
        #expect(throws: PathGuardViolation.self) { try pathGuard.checkLocation(roundTrip) }
    }

    @Test func refusesRelativeAndNonFileURLs() throws {
        let relative = URL(fileURLWithPath: "relative/path", relativeTo: nil)
        // URL(fileURLWithPath:) makes relative paths absolute against the working
        // directory, which lies outside the allowed folder.
        #expect(throws: PathGuardViolation.self) { try pathGuard.checkLocation(relative) }
        let web = try #require(URL(string: "https://example.com/allowed"))
        let error = #expect(throws: PathGuardViolation.self) { try pathGuard.checkLocation(web) }
        #expect(error?.reason == .notAFileURL)
    }

    @Test func refusesASymlinkedFolderThatLeadsOutside() throws {
        try sandbox.write("outside/secret.txt", "secret")
        try sandbox.symlink("allowed/escape", to: outside.path)
        // Anything reached through the link resolves outside.
        #expect(throws: PathGuardViolation.self) {
            try pathGuard.checkLocation(allowed.appendingPathComponent("escape/secret.txt"))
        }
        #expect(throws: PathGuardViolation.self) {
            try pathGuard.checkTarget(allowed.appendingPathComponent("escape"))
        }
        // The link itself lives inside, so renaming or trashing it is allowed.
        #expect(try pathGuard.checkLocation(allowed.appendingPathComponent("escape")).path == allowed.path + "/escape")
    }

    @Test func refusesARelativeSymlinkThatLeadsOutside() throws {
        try sandbox.write("outside/secret.txt", "secret")
        try sandbox.symlink("allowed/sneaky", to: "../outside/secret.txt")
        #expect(throws: PathGuardViolation.self) { try pathGuard.checkTarget(allowed.appendingPathComponent("sneaky")) }
    }

    @Test func refusesADanglingSymlinkInThePath() throws {
        try sandbox.symlink("allowed/dangling", to: "/nonexistent-\(UUID().uuidString)")
        let error = #expect(throws: PathGuardViolation.self) {
            try pathGuard.checkLocation(allowed.appendingPathComponent("dangling/child"))
        }
        #expect(error?.reason == .unresolvable)
    }

    @Test func followsSymlinksThatStayInside() throws {
        try sandbox.mkdir("allowed/real")
        try sandbox.symlink("allowed/alias", to: "real")
        #expect(try pathGuard.checkTarget(allowed.appendingPathComponent("alias")).path == allowed.path + "/real")
    }

    @Test func resolvesASymlinkedRoot() throws {
        // /tmp is a symlink to /private/tmp; a root given through a symlink
        // must still match the resolved paths.
        try sandbox.symlink("root-link", to: allowed.path)
        let viaLink = PathGuard.restricted(to: [sandbox.url("root-link")])
        try sandbox.write("allowed/a.txt", "a")
        #expect(try viaLink.checkLocation(allowed.appendingPathComponent("a.txt")).path == allowed.path + "/a.txt")
        #expect(throws: PathGuardViolation.self) { try viaLink.checkLocation(outside) }
    }

    @Test func supportsSeveralRoots() throws {
        let both = PathGuard.restricted(to: [allowed, outside])
        #expect(try both.checkLocation(outside.appendingPathComponent("x")).path == outside.path + "/x")
        #expect(throws: PathGuardViolation.self) { try both.checkLocation(sandbox.root) }
    }

    @Test func unrestrictedStillRejectsMalformedPaths() throws {
        #expect(try PathGuard.unrestricted.checkLocation(URL(fileURLWithPath: "/Users")).path == "/Users")
        #expect(throws: PathGuardViolation.self) {
            try PathGuard.unrestricted.checkLocation(URL(fileURLWithPath: "/Users/../etc"))
        }
    }
}
