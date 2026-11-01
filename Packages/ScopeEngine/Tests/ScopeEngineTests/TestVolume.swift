import Foundation
import Testing

@testable import ScopeEngine

/// A small APFS disk image mounted for a test, so operations that use the
/// Trash, or move between disks, never touch the startup disk (whose Trash is
/// the user's own). Detached and deleted afterwards.
final class TestVolume {
    let mountPoint: URL
    /// A fresh folder on the volume; tests work inside it.
    let work: URL
    private let image: URL
    private let folder: URL

    init(name: String = "ScopeOps", sizeMB: Int = 512) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScopeVolume-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Sparse, so the image only takes the space its files use.
        image = folder.appendingPathComponent("\(name).sparsebundle")
        let mount = folder.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try Self.run(
            "/usr/bin/hdiutil",
            [
                "create", "-size", "\(sizeMB)m", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-volname", name, image.path,
                "-quiet",
            ])
        try Self.run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-mountpoint", mount.path, "-quiet"])
        let resolved = try #require(realpath(mount.path, nil))
        defer { free(resolved) }
        mountPoint = URL(fileURLWithPath: String(cString: resolved))
        work = mountPoint.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    deinit {
        try? Self.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
        try? FileManager.default.removeItem(at: folder)
    }

    func url(_ relative: String) -> URL { work.appendingPathComponent(relative) }

    /// Force-detaches the volume mid-test, as pulling the disk out would.
    func detach() throws {
        try Self.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
    }

    @discardableResult
    func write(_ relative: String, _ contents: String) throws -> URL {
        try write(relative, Data(contents.utf8))
    }

    @discardableResult
    func write(_ relative: String, _ data: Data) throws -> URL {
        let target = url(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }

    func exists(_ relative: String) -> Bool {
        FileEngine.lstatInfo(url(relative).path) != nil
    }

    func read(_ relative: String) throws -> String {
        try String(contentsOf: url(relative), encoding: .utf8)
    }

    func names(_ relative: String = "") throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url(relative).path).sorted()
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(
                .fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "\(tool) \(arguments.first ?? "") failed"])
        }
    }
}

/// Runs operations straight through the engine and reports the undo steps.
struct OperationHarness {
    let engine: FileEngine
    var conflictAnswer: ConflictChoice = .stop

    @discardableResult
    func run(_ kind: FileOperation.Kind, control: OperationControl = OperationControl()) async throws -> UndoRecord {
        let undo = UndoRecorder()
        let answer = conflictAnswer
        try await engine.run(FileOperation(kind), control: control, undo: undo) { _ in (answer, false) }
        return UndoRecord(title: "test", steps: undo.recorded)
    }

    func undo(_ record: UndoRecord) async throws {
        try await run(.undo(record))
    }
}
