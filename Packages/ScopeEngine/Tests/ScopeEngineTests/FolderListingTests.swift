import CoreServices
import Foundation
import Testing

@testable import ScopeEngine

/// Updating a listing from the names a change reports, and turning two
/// listings into row inserts, removals and reloads.
@Suite struct FolderListingTests {
    let sandbox: Sandbox

    init() throws {
        sandbox = try Sandbox()
    }

    private func items(_ names: [String]) throws -> [FileItem] {
        try names.map { try FileItem(url: sandbox.url($0)) }
    }

    @Test func rereadsOnlyTheNamedChildren() async throws {
        try sandbox.write("a.txt", "a")
        try sandbox.write("b.txt", "b")
        try sandbox.write("c.txt", "c")
        let before = try await sandbox.engine.contentsOfDirectory(at: sandbox.root).sorted { $0.name < $1.name }

        try FileManager.default.removeItem(at: sandbox.url("a.txt"))
        try sandbox.write("b.txt", "bigger now")
        try sandbox.write("d.txt", "d")
        let names: Set = ["a.txt", "b.txt", "d.txt"]
        let fresh = try await sandbox.engine.children(named: names, in: sandbox.root)
        #expect(Set(fresh.map(\.name)) == ["b.txt", "d.txt"])

        let after = FolderListing.updating(before, names: names, with: fresh)
        #expect(after.map(\.name) == ["b.txt", "c.txt", "d.txt"])
        #expect(after[0].size == 10)
        // The same as reading the whole folder again.
        let full = try await sandbox.engine.contentsOfDirectory(at: sandbox.root)
        #expect(Set(after) == Set(full))
    }

    @Test func refusesNamesThatLeaveTheFolder() async throws {
        try sandbox.write("inside/a.txt", "a")
        try sandbox.write("secret.txt", "s")
        let fresh = try await sandbox.engine.children(
            named: ["../secret.txt", "..", ".", "", "a.txt"], in: sandbox.url("inside"))
        #expect(fresh.map(\.name) == ["a.txt"])
    }

    @Test func rowChangesTurnTheOldRowsIntoTheNew() throws {
        for name in ["a", "b", "c", "d", "e"] { try sandbox.write(name, name) }
        let old = try items(["a", "b", "c", "d"])
        try sandbox.write("c", "changed")
        let new = try items(["a", "c", "d", "e"])

        let changes = FolderListing.rowChanges(from: old, to: new)
        #expect(changes.removed == [1])
        #expect(changes.inserted == [3])
        #expect(changes.reloaded == [1])

        // Applying them as a table view would gives the new rows.
        var rows = old.map(\.url)
        for index in changes.removed.reversed() { rows.remove(at: index) }
        for index in changes.inserted { rows.insert(new[index].url, at: index) }
        #expect(rows == new.map(\.url))
    }

    @Test func noChangeIsEmpty() throws {
        for name in ["a", "b"] { try sandbox.write(name, name) }
        let rows = try items(["a", "b"])
        #expect(FolderListing.rowChanges(from: rows, to: rows).isEmpty)
    }

    @Test func randomEditsAlwaysApplyCleanly() throws {
        let names = (0..<40).map { String(format: "f%02d", $0) }
        for name in names { try sandbox.write(name, name) }
        let all = try items(names)
        var random = SeededRandom(seed: 42)
        for _ in 0..<200 {
            let old = all.filter { _ in Bool.random(using: &random) }.shuffled(using: &random)
            let new = all.filter { _ in Bool.random(using: &random) }.shuffled(using: &random)
            let changes = FolderListing.rowChanges(from: old, to: new)
            var rows = old.map(\.url)
            for index in changes.removed.reversed() { rows.remove(at: index) }
            for index in changes.inserted { rows.insert(new[index].url, at: index) }
            #expect(rows == new.map(\.url))
        }
    }
}

@Suite struct FolderChangeTests {
    private let folder = "/Volumes/Disk/folder"
    private let none = FSEventStreamEventFlags(kFSEventStreamEventFlagNone)

    @Test func namesTheDirectChildren() {
        let change = FolderWatcher.change(
            in: folder, paths: [folder + "/a.txt", folder + "/sub/deep.txt", "/elsewhere/x", folder + "/b"],
            flags: [none, none, none, none])
        #expect(change == .children(["a.txt", "b"]))
    }

    @Test func otherPathsAreNoChange() {
        #expect(FolderWatcher.change(in: folder, paths: [folder + "/sub/deep.txt"], flags: [none]) == nil)
    }

    @Test func rescansAndTheFolderItselfMeanEverything() {
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        let root = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        #expect(FolderWatcher.change(in: folder, paths: [folder + "/a"], flags: [rescan]) == .everything)
        #expect(FolderWatcher.change(in: folder, paths: ["/Volumes/Disk"], flags: [root]) == .everything)
        let removed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
        #expect(FolderWatcher.change(in: folder, paths: [folder], flags: [removed]) == .everything)
        // A change to the folder's own details isn't one to its listing.
        #expect(FolderWatcher.change(in: folder, paths: [folder], flags: [none]) == nil)
    }

    @Test func changesMerge() {
        #expect(FolderChange.children(["a"]).merged(with: .children(["b"])) == .children(["a", "b"]))
        #expect(FolderChange.children(["a"]).merged(with: .everything) == .everything)
        let pending = PendingChange()
        pending.add(.children(["a"]))
        pending.add(.children(["b"]))
        #expect(pending.take() == .children(["a", "b"]))
        #expect(pending.take() == nil)
    }
}

@Suite struct FolderEventsTests {
    @Test func reportsTheNamesOfChangedChildren() async throws {
        let sandbox = try Sandbox()
        try sandbox.mkdir("watched")
        let events = try FolderWatcher.events(
            in: sandbox.url("watched"), pathGuard: sandbox.engine.pathGuard, latency: 0.05)

        // FSEvents needs a moment to start delivering.
        try await Task.sleep(for: .milliseconds(300))
        try sandbox.write("watched/new.txt", "new")
        try sandbox.write("watched/other.txt", "other")

        let seen = await withTaskGroup(of: Set<String>.self) { group in
            group.addTask {
                var names: Set<String> = []
                for await change in events {
                    guard case .children(let changed) = change else { continue }
                    names.formUnion(changed)
                    if names.isSuperset(of: ["new.txt", "other.txt"]) { return names }
                }
                return names
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
        #expect(seen == ["new.txt", "other.txt"])
    }
}
