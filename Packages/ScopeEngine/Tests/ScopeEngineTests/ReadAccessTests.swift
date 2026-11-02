import Foundation
import Testing

@testable import ScopeEngine

struct ReadAccessTests {
    @MainActor @Test func listingSetupDoesNotWaitForPathResolution() async throws {
        let sandbox = try Sandbox()
        var engine = sandbox.engine
        let resolvedOnMain = Recorded<Bool>()
        engine.readValidationHook = {
            resolvedOnMain.append(Thread.isMainThread)
            usleep(200_000)
        }
        let start = ContinuousClock.now
        let stream = try engine.listing(of: sandbox.root)
        #expect(ContinuousClock.now - start < .milliseconds(100))
        for try await _ in stream {}
        #expect(resolvedOnMain.all == [false])
    }

    @MainActor @Test func readValidationAndWatcherSetupRunOffMain() async throws {
        let sandbox = try Sandbox()
        var engine = sandbox.engine
        let resolvedOnMain = Recorded<Bool>()
        engine.readValidationHook = { resolvedOnMain.append(Thread.isMainThread) }
        let readable = await engine.readableURLs([sandbox.root, URL(fileURLWithPath: "/etc")])
        #expect(readable.map(\.path) == [sandbox.root.path])
        let events = try await engine.folderEvents(at: sandbox.root)
        let consumer = Task { for await _ in events {} }
        consumer.cancel()
        await consumer.value
        #expect(resolvedOnMain.all == [false, false])
    }
}
