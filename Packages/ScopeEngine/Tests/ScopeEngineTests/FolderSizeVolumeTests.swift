import Foundation
import Testing

@testable import ScopeEngine

/// Like the other disk-image suites, this belongs on an isolated CI/VM host.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CI"] == "true"))
struct FolderSizeVolumeTests {
    @Test func losingTheVolumeDuringCountingThrowsInsteadOfReportingAnEmptyFolder() async throws {
        let volume = try TestVolume(name: "ScopeCountLoss", sizeMB: 64)
        try volume.write("only", "data")
        let mountPoint = volume.mountPoint
        var engine = FileEngine(pathGuard: .restricted(to: [volume.work]))
        engine.folderSizeEntryWillRead = { _ in
            try TestVolume.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
        }
        let progress = Recorded<FolderSize>()
        await #expect(throws: (any Error).self) {
            try await engine.folderSize(of: volume.work) { progress.append($0) }
        }
        #expect(progress.all.isEmpty)
    }
}
