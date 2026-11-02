import Foundation
import Testing

@testable import ScopeEngine

@Suite struct DurabilityTests {
    /// A pipe holds 64 KB. Output read only after the tool exits made a
    /// chatty tool wait for its reader until the timeout killed it.
    @Test func aToolsLargeOutputIsReadWhileItRuns() async throws {
        let started = ContinuousClock.now
        let result = try await FileEngine.runTool(
            "/bin/sh", ["-c", "head -c 300000 /dev/zero; head -c 100000 /dev/zero >&2"], input: nil, timeout: 30)
        #expect(result.status == 0)
        #expect(result.standardOutput.count == 300_000)
        #expect(result.error.utf8.count == 100_000)
        #expect(ContinuousClock.now - started < .seconds(15))
    }

    @Test func aToolThatCantStartThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await FileEngine.runTool("/no/such/tool", [], input: nil, timeout: 5)
        }
    }

    @Test func aToolReadsItsInput() async throws {
        let result = try await FileEngine.runTool("/bin/cat", [], input: "hello", timeout: 10)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "hello\n")
    }

    @Test func syncingAFolderIsBestEffort() throws {
        let sandbox = try Sandbox()
        try sandbox.mkdir("folder")
        FileEngine.syncFolder(sandbox.url("folder").path)
        FileEngine.syncFolder(sandbox.url("missing").path)
        FileEngine.syncFolder(try sandbox.write("file.txt", "x").path)
        #expect(sandbox.exists("folder"))
    }
}
