import Foundation
import Testing

@testable import ScopeEngine

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

    // MARK: - Protected items

    @Test func refusesToModifyFoldersMacOSNeeds() {
        let home = PathGuard.defaultProtectedItems.first { $0.hasPrefix("/Users/") } ?? "/Users"
        for path in ["/", "/Applications", "/Library", "/Users", "/tmp", home, home + "/Library", home + "/Documents"] {
            #expect(throws: PathGuardViolation.self, "\(path)") {
                try PathGuard.unrestricted.checkModifiable(URL(fileURLWithPath: path))
            }
        }
    }

    @Test func protectionIgnoresCaseAndUnicodeForm() {
        let home = PathGuard.defaultProtectedItems.first { $0.hasPrefix("/Users/") } ?? "/Users"
        #expect(throws: PathGuardViolation.self) {
            try PathGuard.unrestricted.checkModifiable(URL(fileURLWithPath: home + "/library"))
        }
        #expect(throws: PathGuardViolation.self) {
            try PathGuard.unrestricted.checkModifiable(URL(fileURLWithPath: "/APPLICATIONS"))
        }
    }

    @Test func protectionCoversOnlyTheItemNotWhatIsInside() throws {
        // Writing into a protected folder is fine; only the folder itself is kept in place.
        #expect(throws: Never.self) {
            try PathGuard.unrestricted.checkWriteLocation(URL(fileURLWithPath: "/Applications/New Folder"))
        }
        try sandbox.write("allowed/a.txt", "a")
        #expect(try pathGuard.checkModifiable(allowed.appendingPathComponent("a.txt")).lastPathComponent == "a.txt")
    }

    @Test func refusesToModifyAVolumeRoot() {
        #expect(throws: PathGuardViolation.self) {
            try PathGuard.unrestricted.checkModifiable(URL(fileURLWithPath: "/System/Volumes/Data"))
        }
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

    // MARK: - Writes only under a scratch folder

    @Test func scratchGuardReadsAnywhereButWritesOnlyInside() throws {
        let scratch = PathGuard.writesOnlyUnder([allowed])
        try sandbox.write("outside/a.txt", "a")
        // Reading is allowed everywhere.
        #expect(try scratch.checkTarget(outside.appendingPathComponent("a.txt")).path == outside.path + "/a.txt")
        #expect(scratch.permits(URL(fileURLWithPath: "/")))
        // Writing only inside the scratch folder, also for items not made yet.
        let created = try scratch.checkWriteLocation(allowed.appendingPathComponent("new/b.txt"))
        #expect(created.path == allowed.path + "/new/b.txt")
        for url in [outside, outside.appendingPathComponent("a.txt"), sandbox.root, URL(fileURLWithPath: "/tmp/x")] {
            #expect(throws: PathGuardViolation.self, "\(url.path)") { try scratch.checkWriteLocation(url) }
            #expect(throws: PathGuardViolation.self, "\(url.path)") { try scratch.checkModifiable(url) }
        }
    }

    @Test func scratchGuardRefusesASiblingThatSharesThePrefix() throws {
        try sandbox.mkdir("allowed-not")
        let scratch = PathGuard.writesOnlyUnder([allowed])
        #expect(throws: PathGuardViolation.self) {
            try scratch.checkWriteLocation(sandbox.url("allowed-not/x.txt"))
        }
    }

    @Test func scratchGuardRefusesASymlinkThatLeadsOut() throws {
        try sandbox.symlink("allowed/escape", to: outside.path)
        let scratch = PathGuard.writesOnlyUnder([allowed])
        // The link itself lives inside and may be trashed; writing through it may not.
        let link = try scratch.checkModifiable(allowed.appendingPathComponent("escape"))
        #expect(link.path == allowed.path + "/escape")
        let violation = #expect(throws: PathGuardViolation.self) {
            try scratch.checkWriteLocation(allowed.appendingPathComponent("escape/new.txt"))
        }
        #expect(violation?.reason == .outsideWritableFolders)
    }

    @Test func scratchFolderCanBeCreatedButNotMovedOrTrashed() throws {
        let missing = sandbox.url("scratch")
        let scratch = PathGuard.writesOnlyUnder([missing])
        #expect(try scratch.checkWriteLocation(missing).path == missing.path)
        try sandbox.mkdir("scratch")
        let violation = #expect(throws: PathGuardViolation.self) { try scratch.checkModifiable(missing) }
        #expect(violation?.reason == .protectedItem)
        try sandbox.write("scratch/a.txt", "a")
        #expect(try scratch.checkModifiable(missing.appendingPathComponent("a.txt")).path == missing.path + "/a.txt")
    }

    @Test func putBackIsAllowedOnlyFromATrash() throws {
        let scratch = PathGuard.writesOnlyUnder([allowed])
        let home = PathGuard.defaultProtectedItems.first { $0.hasPrefix("/Users/") } ?? "/Users/x"
        #expect(PathGuard.isInTrash(home + "/.Trash/a.txt"))
        #expect(PathGuard.isInTrash("/Volumes/Disk/.Trashes/501/a.txt"))
        #expect(!PathGuard.isInTrash(home + "/.Trash"))
        #expect(!PathGuard.isInTrash("/Volumes/Disk/.Trashes/501"))
        #expect(!PathGuard.isInTrash("/Volumes/Disk/.Trashes/x/a.txt"))
        #expect(!PathGuard.isInTrash(home + "/Documents/a.txt"))
        // Outside the scratch folder and outside any Trash: refused.
        #expect(throws: PathGuardViolation.self) { try scratch.checkPutBack(outside.appendingPathComponent("a.txt")) }
        #expect(throws: PathGuardViolation.self) {
            try PathGuard.readOnly.checkPutBack(URL(fileURLWithPath: home + "/.Trash/a.txt"))
        }
    }
}
