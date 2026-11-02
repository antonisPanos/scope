import Foundation
import Testing

@testable import Scope

/// Which folders no tab shows are kept: recent ones, up to a limit, while
/// they can still be read.
struct FolderStoreTests {
    private typealias Idle = (key: String, since: ContinuousClock.Instant, failed: Bool)
    private let now = ContinuousClock.now

    private func idle(_ key: String, secondsAgo: Int, failed: Bool = false) -> Idle {
        (key, now - .seconds(secondsAgo), failed)
    }

    private func evicted(_ idle: [Idle], limit: Int = 3) -> Set<String> {
        Set(FolderStore.evictable(idle, now: now, limit: limit, after: .seconds(120)))
    }

    @Test func keepsRecentFoldersUpToTheLimit() {
        let folders = (1...5).map { idle("/f\($0)", secondsAgo: $0) }
        // The three most recently left stay; the older two go.
        #expect(evicted(folders) == ["/f4", "/f5"])
        #expect(evicted(Array(folders.prefix(3))).isEmpty)
    }

    @Test func dropsFoldersIdleTooLongOrUnreadable() {
        let folders = [
            idle("/old", secondsAgo: 121), idle("/gone", secondsAgo: 1, failed: true), idle("/fresh", secondsAgo: 5),
        ]
        #expect(evicted(folders) == ["/old", "/gone"])
    }

    @Test func keepsNothingWithALimitOfZero() {
        #expect(evicted([idle("/a", secondsAgo: 1)], limit: 0) == ["/a"])
    }
}
