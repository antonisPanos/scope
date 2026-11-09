import Darwin
import Foundation
import Testing

@testable import ScopeEngine

final class BoundedFixture {
    static let byteLimit = 16 * 1024
    static let itemLimit = 16
    let root: URL
    let trash: URL
    var engine: FileEngine
    private var bytes = 0
    private var items = 0

    init() throws {
        let parent = try #require(ProcessInfo.processInfo.environment["SCOPE_BOUNDED_ROOT"])
        root = URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(UUID().uuidString)
        trash = root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("destination"), withIntermediateDirectories: true)
        engine = FileEngine(pathGuard: .restricted(to: [root]))
        engine.trash = .folder(trash)
        engine.copyTestOptions.chunkSize = 128
        engine.copyTestOptions.disableCloning = true
        engine.copyTestOptions.simulateDifferentVolumes = true
        engine.copyTestOptions.destinationLimits = .init(
            fileSystem: "apfs", volumeName: "fixture", freeBytes: 32 * 1024 * 1024)
    }

    deinit {
        do {
            try checkBudget()
        } catch {
            Issue.record("Could not check bounded fixture budget: \(error)")
        }
        do {
            try FileManager.default.removeItem(at: root)
            if FileManager.default.fileExists(atPath: root.path) {
                Issue.record("Bounded fixture still exists after cleanup")
            }
        } catch {
            Issue.record("Could not clean bounded fixture: \(error)")
        }
    }

    func write(_ name: String, count: Int) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", count >= 0,
            bytes + count <= Self.byteLimit, items < Self.itemLimit
        else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        bytes += count
        items += 1
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x61, count: count).write(to: url)
        return url
    }

    func checkBudget() throws {
        let entries = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var count = 0
        var allocated: Int64 = 0
        for case let url as URL in entries {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
            count += 1
            allocated += Int64(info.st_blocks) * 512
        }
        #expect(count <= 32)
        #expect(allocated <= 128 * 1024)
    }
}
