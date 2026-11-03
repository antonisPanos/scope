import Foundation
import Testing

@testable import ScopeEngine

/// Mounting checks write permission for the image itself (#147), and a
/// cancelled tool never starts or keeps running (#150). Nothing is mounted:
/// mount tests use a fake tool runner, and tool tests run only `printf`,
/// `sh` writing into a temporary folder, and `sleep`.
@Suite(.serialized, .timeLimit(.minutes(1))) struct DiskImageSafetyTests {
    /// The fake diskutil: records each call and reports a mount point.
    private final class FakeDiskutil: Sendable {
        let calls = Recorded<[String]>()

        var runner: FileEngine.ToolRunner {
            { [calls] path, arguments, _, _ in
                calls.append([path] + arguments)
                let plist = try PropertyListSerialization.data(
                    fromPropertyList: ["system-entities": [["mount-point": "/Volumes/Fake"]]], format: .xml, options: 0)
                return FileEngine.ToolOutput(status: 0, standardOutput: plist, error: "")
            }
        }
    }

    private func engine(_ pathGuard: PathGuard, _ diskutil: FakeDiskutil) -> FileEngine {
        var engine = FileEngine(pathGuard: pathGuard)
        engine.toolRunner = diskutil.runner
        return engine
    }

    // MARK: - Write permission for the image (#147)

    @Test func aWritableMountOutsideTheWriteRootsIsRefusedBeforeDiskutilRuns() async throws {
        let sandbox = try Sandbox()
        try sandbox.mkdir("scratch")
        let image = try sandbox.write("outside.dmg", "not a real image")
        let diskutil = FakeDiskutil()
        let engine = engine(.writesOnlyUnder([sandbox.url("scratch")]), diskutil)
        await #expect(throws: PathGuardViolation.self) {
            try await engine.mountImage(image, readOnly: false, mountPoint: nil)
        }
        #expect(diskutil.calls.all.isEmpty)
    }

    @Test func aReadOnlyMountOutsideTheWriteRootsPassesReadOnly() async throws {
        let sandbox = try Sandbox()
        try sandbox.mkdir("scratch")
        let image = try sandbox.write("outside.dmg", "not a real image")
        let diskutil = FakeDiskutil()
        let engine = engine(.writesOnlyUnder([sandbox.url("scratch")]), diskutil)
        let mounted = try await engine.mountImage(image, readOnly: true, mountPoint: nil)
        #expect(mounted?.path == "/Volumes/Fake")
        let call = try #require(diskutil.calls.all.first)
        #expect(call.contains("--readOnly"))
        #expect(call.last == image.path)
    }

    @Test func aReadOnlyGuardRefusesWritableMountsOnly() async throws {
        let sandbox = try Sandbox()
        let image = try sandbox.write("image.dmg", "not a real image")
        let diskutil = FakeDiskutil()
        let engine = engine(.readOnly, diskutil)
        await #expect(throws: PathGuardViolation.self) {
            try await engine.mountImage(image, readOnly: false, mountPoint: nil)
        }
        #expect(diskutil.calls.all.isEmpty)
        try await engine.mountImage(image, readOnly: true, mountPoint: nil)
        #expect(diskutil.calls.all.count == 1 && diskutil.calls.all[0].contains("--readOnly"))
    }

    @Test func aLinkInTheScratchFolderIsCheckedAndPassedAsItsTarget() async throws {
        let sandbox = try Sandbox()
        try sandbox.mkdir("scratch")
        let image = try sandbox.write("outside.dmg", "not a real image")
        try sandbox.symlink("scratch/link.dmg", to: image.path)
        let link = sandbox.url("scratch/link.dmg")
        let diskutil = FakeDiskutil()
        let engine = engine(.writesOnlyUnder([sandbox.url("scratch")]), diskutil)
        await #expect(throws: PathGuardViolation.self) {
            try await engine.mountImage(link, readOnly: false, mountPoint: nil)
        }
        #expect(diskutil.calls.all.isEmpty)
        #expect(!engine.pathGuard.permitsWrite(link, followFinalSymlink: true))
        #expect(engine.pathGuard.permitsWrite(link))

        try await engine.mountImage(link, readOnly: true, mountPoint: nil)
        #expect(diskutil.calls.all.first?.last == image.path)
    }

    @Test func anImageInTheScratchFolderMountsWritable() async throws {
        let sandbox = try Sandbox()
        let image = try sandbox.write("scratch/inside.sparseimage", "not a real image")
        let diskutil = FakeDiskutil()
        let engine = engine(.writesOnlyUnder([sandbox.url("scratch")]), diskutil)
        #expect(engine.pathGuard.permitsWrite(image, followFinalSymlink: true))
        try await engine.mountImage(image, readOnly: false, mountPoint: nil)
        let call = try #require(diskutil.calls.all.first)
        #expect(!call.contains("--readOnly"))
        #expect(call.last == image.path)
    }

    @Test func aCancelledMountNeverRunsDiskutil() async throws {
        let sandbox = try Sandbox()
        let image = try sandbox.write("image.dmg", "not a real image")
        let diskutil = FakeDiskutil()
        let engine = engine(.restricted(to: [sandbox.root]), diskutil)
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.mountImage(image, readOnly: true, mountPoint: nil)
        }
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(diskutil.calls.all.isEmpty)
    }

    // MARK: - Cancelling a tool (#150)

    @Test func anAlreadyCancelledTaskNeverStartsTheTool() async throws {
        let sandbox = try Sandbox()
        let marker = sandbox.url("ran")
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FileEngine.runTool(
                "/bin/sh", ["-c", "echo ran > \"$0\"", marker.path], input: nil, timeout: 5)
        }
        await #expect(throws: CancellationError.self) { try await worker.value }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!sandbox.exists("ran"))
    }

    @Test func cancellingARunningToolStopsItAndThrowsCancellation() async throws {
        let started = ContinuousClock.now
        let worker = Task.detached {
            try await FileEngine.runTool("/bin/sleep", ["30"], input: nil, timeout: 45)
        }
        try await Task.sleep(for: .milliseconds(300))
        worker.cancel()
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func cancellingAroundTheStartIsNeverLost() async throws {
        // Each cancel lands somewhere between the task starting and the tool
        // running. A lost one would leave `sleep 5` running to the end.
        let started = ContinuousClock.now
        for _ in 0..<20 {
            let worker = Task.detached {
                try await FileEngine.runTool("/bin/sleep", ["5"], input: nil, timeout: 30)
            }
            worker.cancel()
            await #expect(throws: CancellationError.self) { try await worker.value }
        }
        #expect(ContinuousClock.now - started < .seconds(20))
    }

    @Test func aTimeoutStopsTheToolAndSaysSo() async throws {
        let started = ContinuousClock.now
        let output = try await FileEngine.runTool("/bin/sleep", ["30"], input: nil, timeout: 0.5)
        #expect(output.timedOut)
        #expect(output.status != 0)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func aToolThatFinishesIsNotReportedAsCancelledOrTimedOut() async throws {
        let output = try await FileEngine.runTool("/usr/bin/printf", ["done"], input: nil, timeout: 10)
        #expect(output.status == 0 && !output.timedOut)
        #expect(String(decoding: output.standardOutput, as: UTF8.self) == "done")
    }
}
