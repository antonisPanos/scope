import Foundation
import Testing
@testable import ScopeEngine

@Suite struct SearchTests {
    let sandbox: Sandbox

    init() throws {
        sandbox = try Sandbox()
        try sandbox.write("Report 2026.pdf", "%PDF")
        try sandbox.write("notes.txt", "notes")
        try sandbox.write("photos/IMG_2026_01.jpg", Data(count: 2_000))
        try sandbox.write("photos/IMG_2025_12.jpg", Data(count: 500))
        try sandbox.write("photos/deep/er/IMG_2026_02.png", Data(count: 10))
        try sandbox.write(".hidden/secret-report.txt", "s")
        try sandbox.write("App.app/Contents/report-inside.txt", "p")
        try sandbox.write("Café Résumé.txt", "accents")
        try sandbox.symlink("loop", to: ".")
    }

    private func names(_ query: SearchQuery) async throws -> [String] {
        var found: [String] = []
        for try await batch in try sandbox.engine.search(query, in: sandbox.root) {
            found += batch.map(\.name)
        }
        return found.sorted()
    }

    @Test func containsIsCaseAndAccentInsensitive() async throws {
        #expect(try await names(SearchQuery(text: "report")) == ["Report 2026.pdf"])
        #expect(try await names(SearchQuery(text: "resume")) == ["Café Résumé.txt"])
    }

    @Test func globAndRegex() async throws {
        #expect(try await names(SearchQuery(text: "IMG_2026*", mode: .glob)) == ["IMG_2026_01.jpg", "IMG_2026_02.png"])
        #expect(try await names(SearchQuery(text: "*.PDF", mode: .glob)) == ["Report 2026.pdf"])
        #expect(try await names(SearchQuery(text: #"^IMG_\d{4}_12"#, mode: .regex)) == ["IMG_2025_12.jpg"])
        await #expect(throws: SearchError.self) {
            _ = try await names(SearchQuery(text: "([", mode: .regex))
        }
    }

    @Test func hiddenSubfoldersAndPackages() async throws {
        #expect(try await names(SearchQuery(text: "report", includeHidden: true)) == ["Report 2026.pdf", "secret-report.txt"])
        #expect(try await names(SearchQuery(text: "report", includePackages: true)) == ["Report 2026.pdf", "report-inside.txt"])
        #expect(try await names(SearchQuery(text: "IMG", includeSubfolders: false)) == [])
    }

    @Test func kindSizeAndDateFilters() async throws {
        #expect(try await names(SearchQuery(kinds: [.image])) == ["IMG_2025_12.jpg", "IMG_2026_01.jpg", "IMG_2026_02.png"])
        #expect(try await names(SearchQuery(kinds: [.image], minimumSize: 1_000)) == ["IMG_2026_01.jpg"])
        #expect(try await names(SearchQuery(text: "IMG", maximumSize: 100)) == ["IMG_2026_02.png"])
        let old = sandbox.url("notes.txt")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)
        #expect(try await names(SearchQuery(text: "notes", modifiedAfter: Date(timeIntervalSinceNow: -3600))) == [])
        #expect(try await names(SearchQuery(text: "notes", modifiedBefore: Date(timeIntervalSince1970: 10))) == ["notes.txt"])
    }

    @Test func tagFilter() async throws {
        try (sandbox.url("notes.txt") as NSURL).setResourceValue(["Red"], forKey: .tagNamesKey)
        #expect(try await names(SearchQuery(tag: "red")) == ["notes.txt"])
    }

    @Test func streamsManyResultsAndStopsWhenCancelled() async throws {
        for index in 0..<3_000 { try sandbox.write("many/f\(index)/item-\(index).txt", "x") }
        var batches = 0
        var count = 0
        for try await batch in try sandbox.engine.search(SearchQuery(text: "item-"), in: sandbox.root, batchSize: 100) {
            batches += 1
            count += batch.count
        }
        #expect(count == 3_000)
        #expect(batches > 1)

        // Stopping after the first batch ends the crawl promptly.
        let started = ContinuousClock.now
        for try await _ in try sandbox.engine.search(SearchQuery(text: "item-"), in: sandbox.root, batchSize: 10) { break }
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func refusesFoldersOutsideTheGuard() throws {
        #expect(throws: PathGuardViolation.self) {
            _ = try sandbox.engine.search(SearchQuery(text: "x"), in: URL(fileURLWithPath: "/etc"))
        }
    }
}
