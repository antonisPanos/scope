import Foundation
import ScopeEngine

/// Tags are read on demand, outside drawing callbacks. Each view keeps its
/// current folder's values while refreshing, without flooding the I/O queue.
@MainActor
final class FileTagCache {
    private let readTags: @Sendable (URL) async throws -> [String]
    private let parallelism: Int
    private var values: [URL: [String]] = [:]
    private var waiting: [URL] = []
    private var requested: Set<URL> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generation = 0
    private var closed = false
    private(set) var staleURLs: Set<URL> = []
    var onChange: ((URL) -> Void)?
    var isLoading: Bool { !tasks.isEmpty || !waiting.isEmpty }

    convenience init(engine: FileEngine) {
        self.init(readTags: engine.tags)
    }

    init(parallelism: Int = 8, readTags: @escaping @Sendable (URL) async throws -> [String]) {
        precondition(parallelism > 0)
        self.parallelism = parallelism
        self.readTags = readTags
    }

    isolated deinit { tasks.values.forEach { $0.cancel() } }

    func cachedTags(for url: URL) -> [String]? { values[url] }

    func tags(for url: URL) -> [String]? {
        let cached = values[url]
        guard !closed, cached == nil || staleURLs.contains(url) else { return cached }
        if requested.insert(url).inserted {
            waiting.append(url)
            startReads()
        }
        return cached
    }

    func invalidate(clear: Bool = false) {
        generation += 1
        tasks.values.forEach { $0.cancel() }
        requested = []
        waiting = []
        if clear { values = [:] }
        staleURLs = Set(values.keys)
    }

    func close() {
        closed = true
        invalidate(clear: true)
        onChange = nil
    }

    private func startReads() {
        // Prefer recently displayed rows when scrolling past slow metadata.
        while !closed, tasks.count < parallelism, let url = waiting.popLast() {
            let readTags = readTags
            let generation = generation
            let id = UUID()
            tasks[id] = Task { [weak self] in
                let tags = Task.isCancelled ? [] : ((try? await readTags(url)) ?? [])
                guard let self else { return }
                self.tasks[id] = nil
                guard !Task.isCancelled, self.generation == generation else {
                    self.startReads()
                    return
                }
                let previous = self.values[url] ?? []
                self.requested.remove(url)
                self.staleURLs.remove(url)
                self.values[url] = tags
                if previous != tags { self.onChange?(url) }
                self.startReads()
            }
        }
    }
}
