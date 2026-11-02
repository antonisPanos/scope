import Foundation
import ScopeEngine

/// UI hints for menus and drag setup. Actual opens validate again off the
/// main thread. Unrestricted read policy needs no disk probe for a hint.
@MainActor
final class ReadAccessCache {
    private let engine: FileEngine
    private var values: [URL: (allowed: Bool, expires: ContinuousClock.Instant)] = [:]
    private var pending: [URL: Task<Void, Never>] = [:]
    var onChange: (() -> Void)?

    init(engine: FileEngine) { self.engine = engine }

    isolated deinit { close() }

    func close() {
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        values.removeAll()
    }

    func permits(_ url: URL) -> Bool {
        guard url.isFileURL, url.path.hasPrefix("/") else { return false }
        if !engine.pathGuard.isRestricted { return true }
        if let known = values[url], known.expires > .now { return known.allowed }
        if pending[url] == nil {
            let engine = engine
            pending[url] = Task { [weak self] in
                let allowed = !(await engine.readableURLs([url])).isEmpty
                guard let self, !Task.isCancelled else { return }
                if self.values.count >= 512 { self.values.removeAll() }
                self.values[url] = (allowed, .now + .seconds(5))
                self.pending[url] = nil
                self.onChange?()
            }
        }
        return false
    }
}
