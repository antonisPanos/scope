import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

@Suite(.serialized) struct CopyRaceTests {
    @Test func aSwappedDestinationParentCannotRedirectTheCopyOrCleanup() async throws {
        let sandbox = try Sandbox()
        let outside = try Sandbox()
        try sandbox.mkdir("allowed/destination")
        let source = try sandbox.write("allowed/source.txt", "inside")
        try outside.write("sentinel.txt", "untouched")
        let before = try TreeSnapshot(outside.root)
        let destination = sandbox.url("allowed/destination")
        let saved = sandbox.url("allowed/saved")
        let outsideURL = outside.root
        let swapped = Mutex(false)
        let failures = Recorded<String>()
        let engine = FileEngine(pathGuard: .writesOnlyUnder([sandbox.url("allowed")]))

        await #expect(throws: (any Error).self) {
            try await engine.copyItem(at: source, to: destination.appendingPathComponent("copy.txt")) { _ in
                let first = swapped.withLock { value in
                    let first = !value
                    value = true
                    return first
                }
                guard first else { return }
                do {
                    try FileManager.default.moveItem(at: destination, to: saved)
                    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outsideURL)
                } catch { failures.append(error.localizedDescription) }
            }
        }
        #expect(failures.all.isEmpty)
        #expect(try TreeSnapshot(outside.root) == before)
        #expect(try sandbox.names(in: "allowed/saved").isEmpty)
    }

    @Test(arguments: [UInt32(0), UInt32(UF_NODUMP)])
    func aFileSwappedForASymlinkCannotReadOutsideTheGuard(_ flags: UInt32) async throws {
        let sandbox = try Sandbox()
        let outside = try Sandbox()
        let source = try sandbox.write("source/note.txt", "inside")
        let secret = try outside.write("outside.txt", "outside sentinel")
        _ = chflags(source.path, flags)
        let sourceFolder = sandbox.url("source")
        let saved = sandbox.url("source/saved.txt")
        let swapped = Mutex(false)
        let failures = Recorded<String>()
        await #expect(throws: (any Error).self) {
            try await sandbox.engine.copyItem(at: sourceFolder, to: sandbox.url("copy")) { progress in
                guard progress.currentItem == "note.txt" else { return }
                let first = swapped.withLock { value in
                    let first = !value
                    value = true
                    return first
                }
                guard first else { return }
                do {
                    try FileManager.default.moveItem(at: source, to: saved)
                    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: secret)
                } catch { failures.append(error.localizedDescription) }
            }
        }
        #expect(failures.all.isEmpty)
        #expect(!sandbox.exists("copy"))
        #expect(!((try sandbox.names()).contains { $0.hasPrefix(FileEngine.partialPrefix) }))
        #expect(try String(contentsOf: secret, encoding: .utf8) == "outside sentinel")
    }

    @Test func aDirectorySwappedForASymlinkCannotBeTraversed() async throws {
        let sandbox = try Sandbox()
        let outside = try Sandbox()
        try sandbox.write("source/sub/note.txt", "inside")
        try outside.write("outside.txt", "outside sentinel")
        let folder = sandbox.url("source/sub")
        let saved = sandbox.url("source/saved")
        let outsideURL = outside.root
        let swapped = Mutex(false)
        let failures = Recorded<String>()
        await #expect(throws: (any Error).self) {
            try await sandbox.engine.copyItem(at: sandbox.url("source"), to: sandbox.url("copy")) { progress in
                guard progress.currentItem == "sub" else { return }
                let first = swapped.withLock { value in
                    let first = !value
                    value = true
                    return first
                }
                guard first else { return }
                do {
                    try FileManager.default.moveItem(at: folder, to: saved)
                    try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outsideURL)
                } catch { failures.append(error.localizedDescription) }
            }
        }
        #expect(failures.all.isEmpty)
        #expect(!sandbox.exists("copy"))
        #expect(try outside.names() == ["outside.txt"])
    }

    @Test func aReplacedPartialIsNotPublishedOrDeleted() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("source.txt", "inside")
        let kept = sandbox.url("kept-partial.txt")
        let target = sandbox.url("copy.txt")
        let engine = sandbox.engine
        #expect(throws: (any Error).self) {
            try engine.copyItem(at: source, to: target, control: nil, progress: nil) { _, partial in
                try FileManager.default.moveItem(at: partial, to: kept)
                try Data("replacement sentinel".utf8).write(to: partial, options: .withoutOverwriting)
            }
        }
        #expect(!sandbox.exists("copy.txt"))
        let partial = try #require(try sandbox.names().first { $0.hasPrefix(FileEngine.partialPrefix) })
        #expect(try String(contentsOf: sandbox.url(partial), encoding: .utf8) == "replacement sentinel")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "inside")
    }

    @Test func deferredMetadataDoesNotFollowAChangedSourceDirectory() async throws {
        let sandbox = try Sandbox()
        let outside = try Sandbox()
        try sandbox.write("source/note.txt", "inside")
        try outside.write("note.txt", "outside sentinel")
        setXattr(sandbox.url("source"), "com.example.private-metadata", "must not reach outside")
        let before = try TreeSnapshot(outside.root)
        let source = sandbox.url("source")
        let saved = sandbox.url("saved")
        let outsideURL = outside.root
        let swapped = Mutex(false)
        let failures = Recorded<String>()
        try await sandbox.engine.copyItem(at: source, to: sandbox.url("copy")) { progress in
            guard progress.itemsDone >= 2 else { return }
            let first = swapped.withLock { value in
                let first = !value
                value = true
                return first
            }
            guard first else { return }
            do {
                try FileManager.default.moveItem(at: source, to: saved)
                try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outsideURL)
            } catch { failures.append(error.localizedDescription) }
        }
        #expect(failures.all.isEmpty)
        #expect(swapped.withLock { $0 })
        #expect(try TreeSnapshot(outside.root) == before)
        #expect(try String(contentsOf: sandbox.url("copy/note.txt"), encoding: .utf8) == "inside")
    }

    @Test(arguments: [false, true])
    func clonedDirectoryTraversalPausesAndCanBeCancelled(cancel: Bool) async throws {
        let sandbox = try Sandbox()
        for index in 0..<10 { try sandbox.write("source/\(index).txt", "clone") }
        let engine = sandbox.engine
        let source = sandbox.url("source")
        let destination = sandbox.url("copy")
        let control = OperationControl()
        let paused = Mutex(false)
        let finished = Mutex(false)
        let worker = Task.detached {
            try engine.copyItem(
                at: source, to: destination, control: control,
                progress: { progress in
                    guard progress.itemsDone == 1 else { return }
                    let first = paused.withLock { value in
                        let first = !value
                        value = true
                        return first
                    }
                    if first { control.isPaused = true }
                })
            finished.withLock { $0 = true }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while !paused.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let observedPause = paused.withLock { $0 }
        try await Task.sleep(for: .milliseconds(50))
        let finishedWhilePaused = finished.withLock { $0 }
        if cancel { worker.cancel() }
        control.isPaused = false
        if cancel {
            await #expect(throws: CancellationError.self) { try await worker.value }
            #expect(!sandbox.exists("copy"))
        } else {
            try await worker.value
            #expect(try sandbox.names(in: "copy").count == 10)
        }
        #expect(observedPause)
        #expect(!finishedWhilePaused)
        #expect(!((try sandbox.names()).contains { $0.hasPrefix(FileEngine.partialPrefix) }))
    }
}
