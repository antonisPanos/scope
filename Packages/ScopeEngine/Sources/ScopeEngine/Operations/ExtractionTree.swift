import Foundation

/// Bounds on what an extraction holds in memory, whatever the archive says.
/// Exceeding one stops the extraction and removes what it unpacked.
struct ExtractionLimits: Sendable {
    /// Bytes of macOS metadata held for entries whose data hasn't arrived yet.
    var pendingMetadataBytes = 128 * 1024 * 1024
    /// Files and folders remembered until the end, to set their final
    /// permissions and dates.
    var entries = 1_000_000
}

/// Extraction creates and reopens every entry relative to the pinned staging
/// folder, one component at a time, never following a link. Renaming the
/// staging folder or a folder inside it, or swapping one for a link, can't
/// redirect a write outside it (#145). Paths here are only for messages.
final class ExtractionTree {
    let root: CopyDescriptor
    let path: String
    /// What Launch Services writes for the archive's quarantine, set on the
    /// staging folder and each extracted file and folder by descriptor.
    private(set) var quarantine: Data?

    struct Place {
        let folder: CopyDescriptor
        let name: String
        let path: String
    }

    enum Located {
        case place(Place)
        /// A folder on the way doesn't exist (only when not creating).
        case missing
        /// A folder on the way is a link or a file an earlier entry made.
        case unsafe
    }

    private static let folderFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC

    init(root: CopyDescriptor, path: String) {
        self.root = root
        self.path = path
    }

    /// The open folder that holds `relative`, and the entry's own name in it.
    /// With `creating`, missing folders on the way are made (and quarantined).
    func locate(_ relative: String, creating: Bool) throws -> Located {
        let components = relative.split(separator: "/").map(String.init)
        guard let name = components.last else { return .unsafe }
        var folder = root
        var current = path
        for component in components.dropLast() {
            current += "/" + component
            var raw = openat(folder.raw, component, Self.folderFlags)
            if raw < 0, errno == ENOENT {
                guard creating else { return .missing }
                guard mkdirat(folder.raw, component, 0o755) == 0 else {
                    throw FileEngineError.posix("Create folder", current)
                }
                raw = openat(folder.raw, component, Self.folderFlags)
                folder = try CopyDescriptor(raw, path: current)
                try markQuarantined(folder)
                continue
            }
            guard raw >= 0 else {
                if errno == ELOOP || errno == ENOTDIR { return .unsafe }
                throw FileEngineError.posix("Open folder", current)
            }
            folder = try CopyDescriptor(raw, path: current)
        }
        return .place(Place(folder: folder, name: name, path: current + "/" + name))
    }

    /// The item at `place` without following a link; nil when nothing is there.
    func info(_ place: Place) throws -> stat? {
        var value = stat()
        guard fstatat(place.folder.raw, place.name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw FileEngineError.posix("Read", place.path)
        }
        return value
    }

    /// Opens the regular file or folder at `place`, refusing anything that
    /// isn't the object `expected` describes.
    func open(_ place: Place, matching expected: stat) throws -> CopyDescriptor {
        let directory = expected.st_mode & S_IFMT == S_IFDIR
        let flags = directory ? Self.folderFlags : O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        let descriptor = try CopyDescriptor(openat(place.folder.raw, place.name, flags), path: place.path)
        guard CopyLocation.same(try descriptor.info(), expected) else { throw Self.changed(place.path) }
        return descriptor
    }

    /// Reopens an entry made earlier, which must still be the same object.
    func reopen(_ relative: String, matching expected: stat) throws -> CopyDescriptor {
        guard case .place(let place) = try locate(relative, creating: false) else {
            throw Self.changed(path + "/" + relative)
        }
        return try open(place, matching: expected)
    }

    /// Fresh Launch Services quarantine bytes for the archive's provenance,
    /// set on the staging folder and later on everything else by descriptor.
    /// No path in or above the staging folder is ever written (#159).
    func prepareQuarantine(_ properties: [String: Any]?) throws {
        guard let properties else { return }
        let data = try QuarantineStamp.bytes(for: properties)
        quarantine = data
        try markQuarantined(root)
    }

    func markQuarantined(_ descriptor: CopyDescriptor) throws {
        guard let quarantine else { return }
        try QuarantineStamp.apply(quarantine, to: descriptor.raw, path: path)
    }

    static func changed(_ path: String) -> FileEngineError {
        .posix("Item changed while extracting", path, EBUSY)
    }
}
