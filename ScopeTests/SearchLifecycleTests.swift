import Foundation
import ScopeEngine
import Testing

@testable import Scope

@MainActor struct SearchLifecycleTests {
    // These deliberately nonexistent roots keep the app tests read-only and
    // avoid crawling any real user directory or relying on a Spotlight index.
    private func missingRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ScopeSearchState-" + UUID().uuidString)
    }

    @Test func navigatingBeforeTheSearchTaskStartsDoesNotSetStaleState() async throws {
        let root = missingRoot()
        let model = BrowserModel(
            engine: FileEngine(pathGuard: .readOnly), location: .search(SearchQuery(text: "x"), in: root))
        defer { model.close() }
        model.navigate(to: .folder(root))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!model.location.isSearch)
        #expect(!model.isSearching)
    }

    @Test func navigatingAwayFromAnActiveSearchClearsItsStateImmediately() async throws {
        let root = missingRoot()
        let model = BrowserModel(
            engine: FileEngine(pathGuard: .readOnly), location: .search(SearchQuery(text: "x"), in: root))
        defer { model.close() }
        // Navigate exactly when the search announces its active state,
        // without racing a fast empty crawl or relying on timing.
        var navigated = false
        model.onChange = { [weak model] change in
            guard let model, change.contains(.status), model.isSearching, !navigated else { return }
            navigated = true
            model.navigate(to: .folder(root))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(navigated)
        #expect(!model.location.isSearch)
        #expect(!model.isSearching)
    }
}
