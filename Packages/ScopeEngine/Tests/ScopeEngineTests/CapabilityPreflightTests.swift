import Foundation
import Testing

@testable import ScopeEngine

/// Uses only tiny files in a restricted Sandbox; no volume or system Trash is needed.
@Suite(.serialized) struct CapabilityPreflightTests {
    private func limits(_ links: FileEngine.DestinationLimits.Support) -> FileEngine.DestinationLimits {
        var result = FileEngine.DestinationLimits(fileSystem: "exfat", volumeName: "Test", freeBytes: nil)
        result.symbolicLinks = links
        result.maxFileSize = 2
        return result
    }

    @Test func reportsAllKindsWithRelativePathsBeforeWriting() throws {
        let sandbox = try Sandbox()
        try sandbox.mkdir("source/nested")
        try sandbox.mkdir("destination")
        try sandbox.write("source/nested/bad:name", "abc")
        try sandbox.symlink("source/nested/dangling", to: "missing")
        let capabilities = limits(.unsupported)

        do {
            try sandbox.engine.preflight([sandbox.url("source")], into: sandbox.url("destination"), moving: false) {
                _ in
                capabilities
            }
            Issue.record("The incompatible batch should have been refused")
        } catch let OperationError.incompatibleDestination(report) {
            #expect(report.totalCount == 3)
            #expect(report.entries.contains { $0.path == "source/nested/bad:name" && $0.reason == .invalidName })
            #expect(
                report.entries.contains { $0.path == "source/nested/bad:name" && $0.reason == .fileTooLarge(limit: 2) })
            #expect(
                report.entries.contains {
                    $0.path == "source/nested/dangling" && $0.reason == .symbolicLinksUnsupported
                })
            #expect(report.description.contains("Nothing was copied"))
        }
        #expect(try sandbox.names(in: "destination").isEmpty)
        #expect(sandbox.exists("source/nested/dangling"))
    }

    @Test func unknownLinkSupportStopsAndSupportedLinksAreNotFollowed() throws {
        let sandbox = try Sandbox()
        try sandbox.mkdir("source")
        try sandbox.mkdir("destination")
        try sandbox.symlink("source/link", to: "/this-target-does-not-exist")
        let unknown = limits(.unknown)
        do {
            try sandbox.engine.preflight([sandbox.url("source")], into: sandbox.url("destination"), moving: false) {
                _ in
                unknown
            }
            Issue.record("Unknown link support should have been refused")
        } catch let OperationError.incompatibleDestination(report) {
            #expect(report.entries.first?.reason == .symbolicLinksUnknown)
        }
        let supported = limits(.supported)
        try sandbox.engine.preflight([sandbox.url("source")], into: sandbox.url("destination"), moving: false) { _ in
            supported
        }
    }

    @Test func reportBoundsEntriesAndShowsOmittedCount() {
        var report = PreflightReport(volume: "Test")
        for index in 0..<(PreflightReport.entryLimit + 3) {
            report.add(path: "folder/item\(index)", reason: .invalidName)
        }
        #expect(report.entries.count == PreflightReport.entryLimit)
        #expect(report.totalCount == PreflightReport.entryLimit + 3)
        #expect(report.omittedCount == 3)
        #expect(report.description.contains("3 more incompatibilities not shown"))
    }

    @Test func missingSourceDoesNotProduceAnIncompleteSuccessfulScan() throws {
        let sandbox = try Sandbox()
        try sandbox.mkdir("destination")
        let capabilities = limits(.supported)
        #expect(throws: (any Error).self) {
            try sandbox.engine.preflight([sandbox.url("missing")], into: sandbox.url("destination"), moving: false) {
                _ in
                capabilities
            }
        }
    }

    @Test func capabilityFailureStopsBeforeWriting() throws {
        let sandbox = try Sandbox()
        try sandbox.write("source", "small")
        try sandbox.mkdir("destination")
        #expect(throws: CapabilityFailure.unavailable) {
            try sandbox.engine.preflight([sandbox.url("source")], into: sandbox.url("destination"), moving: false) {
                _ in
                throw CapabilityFailure.unavailable
            }
        }
        #expect(try sandbox.names(in: "destination").isEmpty)
    }

    @Test func cancellationStopsTheScanBeforeWriting() async throws {
        let sandbox = try Sandbox()
        try sandbox.write("source", "small")
        try sandbox.mkdir("destination")
        let engine = sandbox.engine
        let source = sandbox.url("source")
        let destination = sandbox.url("destination")
        let capabilities = limits(.supported)
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try engine.preflight([source], into: destination, moving: false) { _ in capabilities }
        }
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(try sandbox.names(in: "destination").isEmpty)
    }
}

private enum CapabilityFailure: Error { case unavailable }
