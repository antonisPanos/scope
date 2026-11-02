import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

/// A small disk image mounted for a test, so operations that use the Trash,
/// or move between disks, never touch the startup disk (whose Trash is the
/// user's own). Detached and deleted afterwards. APFS unless a test asks for
/// another format, such as "MS-DOS FAT32" (whose name must be at most 11
/// capital letters or digits).
final class TestVolume {
    let mountPoint: URL
    /// A fresh folder on the volume; tests work inside it.
    let work: URL
    private let image: URL
    private let folder: URL
    /// The image's whole disk (/dev/diskN). Detaching by it also works after
    /// a test force-ejected the volume, which leaves the disk attached.
    private let device: String?

    init(name: String = "ScopeOps", sizeMB: Int = 512, fileSystem: String = "APFS") throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScopeVolume-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Sparse, so the image only takes the space its files use.
        image = folder.appendingPathComponent("\(name).sparsebundle")
        let mount = folder.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try Self.run(
            "/usr/bin/hdiutil",
            [
                "create", "-size", "\(sizeMB)m", "-type", "SPARSEBUNDLE", "-fs", fileSystem, "-volname", name,
                image.path, "-quiet",
            ])
        let attached = try Self.output(
            "/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-mountpoint", mount.path, "-plist"])
        device = Self.wholeDisk(fromAttachPlist: attached)
        let resolved = try #require(realpath(mount.path, nil))
        defer { free(resolved) }
        mountPoint = URL(fileURLWithPath: String(cString: resolved))
        work = mountPoint.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    deinit {
        try? Self.run("/usr/bin/hdiutil", ["detach", device ?? mountPoint.path, "-force", "-quiet"])
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

    /// The shortest dev-entry hdiutil reports, which is the whole disk.
    private static func wholeDisk(fromAttachPlist data: Data) -> String? {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        return entities.compactMap { $0["dev-entry"] as? String }.min { $0.count < $1.count }
    }

    /// Runs a tool and returns what it printed.
    static func output(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(
                .fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "\(tool) \(arguments.first ?? "") failed"])
        }
        return data
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
    /// The answer to "delete for good?" on a disk with no Trash.
    var deleteForGood = false
    /// Every "delete for good?" question asked, in order.
    let deletionQuestions = Recorded<PermanentDeletion>()

    @discardableResult
    func run(_ kind: FileOperation.Kind, control: OperationControl = OperationControl()) async throws -> UndoRecord {
        let undo = UndoRecorder()
        let answer = conflictAnswer
        let deleteForGood = deleteForGood
        let questions = deletionQuestions
        try await engine.run(
            FileOperation(kind), control: control, undo: undo, resolveConflict: { _ in (answer, false) },
            confirmPermanentDeletion: { request in
                questions.append(request)
                return deleteForGood
            })
        return UndoRecord(title: "test", steps: undo.recorded)
    }

    func undo(_ record: UndoRecord) async throws {
        try await run(.undo(record))
    }
}

/// Values collected from callbacks on any thread.
final class Recorded<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])

    func append(_ value: Value) {
        values.withLock { $0.append(value) }
    }

    var all: [Value] {
        values.withLock { $0 }
    }
}
