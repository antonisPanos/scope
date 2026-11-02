import Testing

@testable import Scope

/// Any local process can post a dev hook, so a snapshot name must not be
/// able to leave the temporary folder.
@MainActor
struct DevHooksTests {
    @Test func plainNamesAreAccepted() {
        for name in ["window", "list-dark", "Icons_2", "a"] {
            #expect(DevHooks.isValidSnapshotName(name), "\(name)")
        }
    }

    @Test func pathsAndOddNamesAreRefused() {
        let refused = [
            "", "../escape", "../../Users/me/Desktop/photo", "a/b", "/tmp/x", ".", "..", ".hidden", "name.png",
            "with space", "ünïcode", "a\u{0}b", String(repeating: "x", count: 65),
        ]
        for name in refused {
            #expect(!DevHooks.isValidSnapshotName(name), "\(name)")
        }
    }
}
