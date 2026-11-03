import Foundation
import Synchronization
import Testing

@testable import Scope

@MainActor struct FileTagCacheTests {
    private let url = URL(fileURLWithPath: "/tag-cache-fixture/item")

    @Test func requestsAreCoalescedAndMetadataRefreshKeepsTheOldTagsVisible() async throws {
        let state = Mutex((tags: ["Red"], reads: 0))
        let cache = FileTagCache { _ in
            state.withLock {
                $0.reads += 1
                return $0.tags
            }
        }
        defer { cache.close() }
        for _ in 0..<20 { #expect(cache.tags(for: url) == nil) }
        try await waitUntil { !cache.isLoading }
        #expect(cache.tags(for: url) == ["Red"])
        #expect(state.withLock { $0.reads } == 1)
        state.withLock { $0.tags = ["Blue", "Work"] }
        cache.invalidate()
        #expect(cache.tags(for: url) == ["Red"])
        try await waitUntil { !cache.isLoading }
        #expect(cache.tags(for: url) == ["Blue", "Work"])
        #expect(state.withLock { $0.reads } == 2)
    }

    @Test func navigationRejectsLateRepliesFromThePreviousLocation() async throws {
        let replies = Mutex<[CheckedContinuation<[String], Never>]>([])
        let cache = FileTagCache(parallelism: 2) { _ in
            await withCheckedContinuation { reply in replies.withLock { $0.append(reply) } }
        }
        defer { cache.close() }
        _ = cache.tags(for: url)
        try await waitUntil { replies.withLock { $0.count } == 1 }
        cache.invalidate(clear: true)
        _ = cache.tags(for: url)
        try await waitUntil { replies.withLock { $0.count } == 2 }
        let callbacks = replies.withLock { $0 }
        callbacks[1].resume(returning: ["Blue"])
        try await waitUntil { cache.cachedTags(for: url) == ["Blue"] }
        callbacks[0].resume(returning: ["Red"])
        try await waitUntil { !cache.isLoading }
        #expect(cache.cachedTags(for: url) == ["Blue"])
    }

    @Test func closingCancelsReadsAndDoesNotReadAnyQueuedItems() async throws {
        let state = Mutex((active: 0, maximum: 0, started: 0))
        let cache = FileTagCache(parallelism: 4) { _ in
            state.withLock {
                $0.active += 1
                $0.started += 1
                $0.maximum = max($0.maximum, $0.active)
            }
            defer { state.withLock { $0.active -= 1 } }
            try await Task.sleep(for: .seconds(60))
            return ["Red"]
        }
        for index in 0..<100 { _ = cache.tags(for: url.appendingPathComponent("\(index)")) }
        try await waitUntil { state.withLock { $0.active } == 4 }
        cache.close()
        try await waitUntil { !cache.isLoading }
        #expect(state.withLock { $0.maximum } == 4)
        #expect(state.withLock { $0.started } == 4)
        #expect(state.withLock { $0.active } == 0)
        #expect(cache.tags(for: url) == nil)
    }

    @Test func refreshesDoNotStartNewReadsUntilCancelledReadsFinish() async throws {
        let replies = Mutex<[CheckedContinuation<[String], Never>]>([])
        let cache = FileTagCache(parallelism: 1) { _ in
            await withCheckedContinuation { reply in replies.withLock { $0.append(reply) } }
        }
        defer { cache.close() }
        _ = cache.tags(for: url)
        try await waitUntil { replies.withLock { $0.count } == 1 }
        cache.invalidate()
        _ = cache.tags(for: url)
        #expect(replies.withLock { $0.count } == 1)
        let first = replies.withLock { $0[0] }
        first.resume(returning: ["Red"])
        try await waitUntil { replies.withLock { $0.count } == 2 }
        let second = replies.withLock { $0[1] }
        second.resume(returning: ["Green"])
        try await waitUntil { !cache.isLoading }
        #expect(cache.cachedTags(for: url) == ["Green"])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}
