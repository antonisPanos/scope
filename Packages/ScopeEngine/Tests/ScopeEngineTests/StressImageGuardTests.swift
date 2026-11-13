import Foundation
import Testing

@testable import ScopeEngine

@Suite(.serialized) struct StressImageGuardTests {
    @Test func mountedGuardAllowsOnlyItsPinnedVolume() throws {
        let volume = try TestVolume(name: "ScopeGate")
        let outside = try Sandbox()
        let guardPolicy = try PathGuard.restrictedToMountedVolumes([volume.mountPoint])
        let inside = volume.url("new-folder/file.txt")
        #expect(guardPolicy.permits(inside))
        #expect(guardPolicy.permitsWrite(inside))
        #expect(throws: PathGuardViolation.self) { try guardPolicy.checkTarget(outside.root) }
        #expect(throws: PathGuardViolation.self) { try guardPolicy.checkWriteLocation(outside.url("sentinel")) }
        #expect(throws: PathGuardViolation.self) { try guardPolicy.checkModifiable(volume.mountPoint) }
    }

    @Test func symlinkEscapeAndDetachFailClosed() throws {
        let volume = try TestVolume(name: "ScopeGate")
        let outside = try Sandbox()
        let sentinel = try outside.write("sentinel.txt", "unchanged")
        let link = volume.url("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
        let guardPolicy = try PathGuard.restrictedToMountedVolumes([volume.mountPoint])
        #expect(throws: PathGuardViolation.self) { try guardPolicy.checkTarget(link) }
        #expect(guardPolicy.permitsWrite(link))  // Removing the link itself stays on the image.
        try volume.detach()
        let refusal = #expect(throws: PathGuardViolation.self) {
            try guardPolicy.checkWriteLocation(volume.mountPoint.appendingPathComponent("new.txt"))
        }
        #expect(refusal?.reason == .volumeChanged)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "unchanged")
    }

    @Test func unmountedFolderCannotBeUsedAsImageRoot() throws {
        let outside = try Sandbox()
        #expect(throws: CocoaError.self) { try PathGuard.restrictedToMountedVolumes([outside.root]) }
    }

    @Test func availableCapacityStopsAtThePinnedMount() async throws {
        let volume = try TestVolume(name: "ScopeGate")
        let outside = try Sandbox()
        let engine = FileEngine(pathGuard: try PathGuard.restrictedToMountedVolumes([volume.mountPoint]))
        let capacity = try #require(await engine.availableCapacity(at: volume.work))
        #expect(capacity > 0)
        #expect(await engine.availableCapacity(at: outside.root) == nil)
        try volume.detach()
        #expect(await engine.availableCapacity(at: volume.mountPoint) == nil)
    }
}
