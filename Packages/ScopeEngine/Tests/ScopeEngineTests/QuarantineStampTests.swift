import CoreServices
import Foundation
import Testing

@testable import ScopeEngine

/// Quarantine for extracted and compressed items is made on a private helper
/// and set by descriptor, so swapping a folder or name never redirects the
/// write (#159). Two small temporary fixtures; links are removed without
/// being followed before teardown.
@Suite struct QuarantineStampTests {
    let sandbox: Sandbox
    let outside: Sandbox

    init() throws {
        sandbox = try Sandbox()
        outside = try Sandbox()
    }

    private let properties: [String: Any] = [
        kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        kLSQuarantineAgentNameKey as String: "ScopeStampTest",
        kLSQuarantineTimeStampKey as String: Date(timeIntervalSince1970: 1_700_000_000),
    ]

    private func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, QuarantineStamp.attributeName, nil, 0, 0, XATTR_NOFOLLOW) > 0
    }

    @Test func bytesComeFromLaunchServicesAndLeaveNothingBehind() throws {
        var helper: String?
        let data = try QuarantineStamp.bytes(for: properties) { helper = $0 }
        // Recent Launch Services versions can omit the agent name from the raw
        // xattr even when it was supplied in quarantineProperties.
        #expect(!data.isEmpty)
        let folder = try #require(helper.map { ($0 as NSString).deletingLastPathComponent })
        #expect(FileEngine.lstatInfo(folder) == nil)
    }

    @Test func aSwappedHelperNameNeverMarksWhatItPointsTo() throws {
        let target = try outside.write("target.txt", "outside")
        let before = try TreeSnapshot(outside.root)
        var helper: String?
        let data = try? QuarantineStamp.bytes(for: properties) { path in
            helper = path
            #expect(rename(path, path + "-moved") == 0)
            #expect(symlink(target.path, path) == 0)
        }
        let path = try #require(helper)
        // Either the helper itself was marked by its ID, or the swap was
        // noticed; the file the link points to is never changed.
        if let data { #expect(!data.isEmpty) }
        #expect(!hasQuarantine(target))
        #expect(try TreeSnapshot(outside.root) == before)
        _ = unlink(path)
        _ = unlink(path + "-moved")
        _ = rmdir((path as NSString).deletingLastPathComponent)
    }

    /// The issue's reproduction: the folder above the pinned staging folder
    /// is moved and replaced by a link to an outside folder of the same shape.
    @Test func aSwappedStagingAncestorNeverQuarantinesTheOutside() throws {
        try sandbox.mkdir("work/staging")
        try outside.mkdir("staging")
        let before = try TreeSnapshot(outside.root)
        let stagingPath = sandbox.url("work/staging").path
        let root = try CopyDescriptor(open(stagingPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW), path: stagingPath)
        let tree = ExtractionTree(root: root, path: stagingPath)
        #expect(rename(sandbox.url("work").path, sandbox.url("moved").path) == 0)
        #expect(symlink(outside.root.path, sandbox.url("work").path) == 0)
        defer { _ = unlink(sandbox.url("work").path) }

        try tree.prepareQuarantine(properties)
        #expect(hasQuarantine(sandbox.url("moved/staging")))
        #expect(!hasQuarantine(outside.url("staging")))
        #expect(try TreeSnapshot(outside.root) == before)
    }
}
