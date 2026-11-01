import Darwin
import Foundation

/// The kernel's list of mounted file systems, for telling which disk a path
/// is on without asking that disk.
///
/// It is read with `MNT_NOWAIT`, which returns what the kernel already knows
/// and never waits on a file system, so a sleeping disk or a lost network
/// share can't stall the caller. That makes it safe on the main thread, such
/// as for the move or copy badge on every mouse move of a drag. Paths are
/// matched by prefix and not resolved, so the answer is a good guess rather
/// than a fact: `FileEngine.areOnSameDisk(_:as:)` is the exact check.
public struct MountTable: Sendable {
    /// Mount points, longest first, so the first match is the innermost one.
    let mountPoints: [String]

    public init() {
        self.init(mountPoints: Self.read())
    }

    init(mountPoints: [String]) {
        self.mountPoints = Set(mountPoints + ["/"]).sorted { $0.count > $1.count }
    }

    /// The mount point of the disk `path` is on.
    public func mountPoint(of path: String) -> String {
        mountPoints.first { $0 == "/" || path == $0 || path.hasPrefix($0 + "/") } ?? "/"
    }

    /// Whether every URL seems to be on the same disk as `folder`.
    public func seemOnSameDisk(_ urls: [URL], as folder: URL) -> Bool {
        let disk = mountPoint(of: folder.path)
        return urls.allSatisfy { mountPoint(of: $0.path) == disk }
    }

    private static func read() -> [String] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        // Room for a few mounts that appear between the two calls.
        var buffer = [statfs](repeating: statfs(), count: Int(count) + 8)
        let filled = buffer.withUnsafeMutableBufferPointer { pointer in
            getfsstat(pointer.baseAddress, Int32(pointer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard filled > 0 else { return [] }
        return buffer.prefix(Int(filled)).map { volume in
            withUnsafeBytes(of: volume.f_mntonname) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
    }
}

extension FileEngine {
    /// Whether every item is on the same disk as `folder`, the test a move
    /// uses. A drop moves items when this holds and copies them otherwise.
    /// False when any of them is missing or outside the guard, so the caller
    /// falls back to a copy, which leaves the originals alone.
    public func areOnSameDisk(_ urls: [URL], as folder: URL) async -> Bool {
        await onIOThreads {
            guard pathGuard.permits(folder), let disk = Self.statInfo(folder.path)?.st_dev else { return false }
            for (index, url) in urls.enumerated() {
                if index % 256 == 0, Task.isCancelled { return false }
                guard pathGuard.permits(url.deletingLastPathComponent()),
                    Self.lstatInfo(url.path)?.st_dev == disk
                else { return false }
            }
            return true
        }
    }

    static func statInfo(_ path: String) -> stat? {
        var info = stat()
        return stat(path, &info) == 0 ? info : nil
    }
}
