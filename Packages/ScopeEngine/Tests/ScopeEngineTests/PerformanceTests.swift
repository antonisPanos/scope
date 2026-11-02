import Foundation
import Testing

@testable import ScopeEngine

/// Speed checks against a folder of 100,000 files on a throwaway disk image.
/// Targets from the scoping doc: a 10,000-item folder lists in under 500 ms.
/// These record timings and fail only far beyond the target, to stay stable on
/// busy machines. One test, so the folder is built once and the image is
/// detached when it ends.
@Suite struct PerformanceTests {
    static let fileCount = 100_000

    /// The Thread Sanitizer slows everything about four times (CI runs these
    /// tests under it too), so the limits stretch to match there. The counts
    /// are checked the same either way.
    static let slack: Int64 = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") == nil ? 1 : 4

    static func limit(_ duration: Duration) -> Duration { duration * slack }

    @Test func bigFolderListsSortsUpdatesAndSearches() async throws {
        let volume = try TestVolume(name: "ScopePerf", sizeMB: 1024)
        let many = volume.url("many")
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        let built = try ContinuousClock().measure { try Self.makeEmptyFiles(Self.fileCount, in: many) }
        print("Made \(Self.fileCount) files in \(built)")
        let engine = FileEngine(pathGuard: .restricted(to: [volume.work]))

        let all = try await listsAndSortsTheBigFolder(many, engine: engine)
        for count in [10_000, 100_000] { try updatesABigListingInPlace(all, count: count) }
        try await searchesTheWholeVolume(volume.work, engine: engine)
    }

    private func listsAndSortsTheBigFolder(_ many: URL, engine: FileEngine) async throws -> [FileItem] {
        let clock = ContinuousClock()
        var items: [FileItem] = []
        let listing = try await clock.measure {
            items = try await engine.contentsOfDirectory(at: many)
        }
        let sorting = clock.measure { _ = FileSort(key: .name).sorted(items) }
        print("Listed \(items.count) items in \(listing), sorted by name in \(sorting)")
        #expect(items.count == Self.fileCount)
        // 100,000 items is ten times the target folder size, so allow ten times the time, plus slack.
        #expect(listing < Self.limit(.seconds(10)))
        #expect(sorting < Self.limit(.seconds(5)))
        return items
    }

    /// What a change on disk costs a tab at 10,000 and 100,000 items: merging
    /// the re-read names into the listing, sorting, and working out which
    /// rows changed. Ten items change, as when a copy lands.
    private func updatesABigListingInPlace(_ all: [FileItem], count: Int) throws {
        try #require(all.count >= count)
        let sort = FileSort(key: .name)
        let old = sort.sorted(Array(all.prefix(count)))
        // Ten names leave and ten others (from beyond the prefix, or the first ten again) arrive.
        let leaving = Set(old.prefix(10).map(\.url.lastPathComponent))
        let arriving = Array(all.dropFirst(count).prefix(10))
        let names = leaving.union(arriving.map(\.url.lastPathComponent))

        let clock = ContinuousClock()
        var changes = FolderListing.RowChanges()
        let elapsed = clock.measure {
            let updated = FolderListing.updating(old, names: names, with: arriving)
            changes = FolderListing.rowChanges(from: old, to: sort.sorted(updated))
        }
        print("Updated \(count) items in place in \(elapsed)")
        #expect(changes.removed.count == 10)
        #expect(changes.inserted.count == arriving.count)
        // A tab redraws within a frame or two at 10,000 items; allow slack at 100,000.
        #expect(elapsed < Self.limit(count > 10_000 ? .seconds(3) : .milliseconds(500)))
    }

    private func searchesTheWholeVolume(_ root: URL, engine: FileEngine) async throws {
        let clock = ContinuousClock()
        var found = 0
        var firstResult: Duration?
        let start = clock.now
        for try await batch in try engine.search(SearchQuery(text: "file-0999"), in: root) {
            if firstResult == nil { firstResult = clock.now - start }
            found += batch.count
        }
        let total = clock.now - start
        print("Searched the volume in \(total), first result after \(firstResult ?? .zero), \(found) found")
        // file-099900.txt to file-099999.txt
        #expect(found == 100)
        #expect(total < Self.limit(.seconds(15)))
    }

    /// Empty files named file-000000.txt and up: no data blocks, so the image
    /// stays small and the folder is quick to build.
    private static func makeEmptyFiles(_ count: Int, in folder: URL) throws {
        for index in 0..<count {
            let path = folder.path + "/" + String(format: "file-%06d.txt", index)
            let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            close(descriptor)
        }
    }
}
