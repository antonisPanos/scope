import Darwin
import Foundation

/// Experimental recovery metadata. This type never removes or renames a partial.
/// Its root must already exist, be private, and be supplied by the caller. All
/// methods do blocking I/O and must run on the engine's I/O executor.
final class RecoveryJournal: @unchecked Sendable {
    static let maxRecords = 128
    static let maxRecordBytes = 16 * 1024
    static let maxPathBytes = 2048
    // Includes locks and interrupted temporary files. Never scan an unbounded store.
    static let maxEntries = 512

    struct Identity: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let kind: UInt32
        let birthSeconds: Int64
        let birthNanoseconds: Int64

        init(_ info: stat) {
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
            kind = UInt32(info.st_mode & S_IFMT)
            birthSeconds = Int64(info.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
        }
    }

    enum Phase: String, Codable, Sendable { case intent, staging, publishing, published, resolved }
    enum Action: String, Codable, Sendable { case copy, move }

    struct Record: Codable, Sendable {
        let version: Int
        let id: UUID
        let session: UUID
        let sessionIdentity: Identity
        let source: String
        let destination: String
        let stagingName: String
        let parent: Identity
        let action: Action
        var phase: Phase
        var staging: Identity?
        var published: Identity?
    }

    enum Ownership: Equatable, Sendable { case active, candidate, ambiguous, published, resolved }
    struct Discovery: Sendable {
        let record: Record
        let ownership: Ownership
    }
    enum Failure: Error {
        case invalidStore, busy, limit, malformed, invalidTransition
        case io(Int32)
    }

    private let root: CopyDescriptor
    private let sessionLock: CopyDescriptor
    let sessionID: UUID
    private let mutex = NSLock()
    private let pathGuard: PathGuard
    private let rootURL: URL
    private let recordLimit: Int

    init(
        root url: URL, pathGuard: PathGuard, sessionID: UUID = UUID(), recordLimit: Int = RecoveryJournal.maxRecords
    ) throws {
        guard (1...Self.maxRecords).contains(recordLimit) else { throw Failure.limit }
        let checked = try pathGuard.checkWriteLocation(url)
        guard checked.path == url.standardizedFileURL.path else { throw Failure.invalidStore }
        let fd = Darwin.open(checked.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        let directory = try CopyDescriptor(fd, path: checked.path)
        let info = try directory.info()
        guard info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else { throw Failure.invalidStore }
        self.root = directory
        self.sessionID = sessionID
        self.pathGuard = pathGuard
        self.rootURL = checked
        self.recordLimit = recordLimit
        // Serialize session creation. One entry remains reserved for a later
        // session to run bounded metadata maintenance after a crash.
        let storeFD = openat(fd, "store.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        let storeLock = try CopyDescriptor(storeFD, path: "store.lock")
        let storeInfo = try storeLock.info()
        guard storeInfo.st_uid == getuid(), storeInfo.st_mode & S_IFMT == S_IFREG,
            storeInfo.st_mode & 0o7777 == 0o600, storeInfo.st_nlink == 1
        else { throw Failure.invalidStore }
        guard flock(storeFD, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        defer { flock(storeFD, LOCK_UN) }
        var namedStore = stat()
        guard fstatat(fd, "store.lock", &namedStore, AT_SYMLINK_NOFOLLOW) == 0,
            Identity(namedStore) == Identity(storeInfo), try Self.names(in: fd).count < Self.maxEntries
        else {
            throw Failure.invalidStore
        }
        let name = "session-" + sessionID.uuidString
        let lockFD = openat(fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        let lock = try CopyDescriptor(lockFD, path: name)
        let sessionInfo = try lock.info()
        guard sessionInfo.st_uid == getuid(), sessionInfo.st_mode & S_IFMT == S_IFREG,
            sessionInfo.st_mode & 0o7777 == 0o600, sessionInfo.st_nlink == 1
        else { throw Failure.invalidStore }
        guard flock(lock.raw, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        self.sessionLock = lock
        do {
            try sync(lock.raw)
            try sync(root.raw)
            try maintainLocked()
        } catch {
            try? removeMetadata(name, expected: Identity(sessionInfo))
            try? sync(root.raw)
            throw error
        }
    }

    func createIntent(
        source: URL, destination: URL, stagingName: String, action: Action, expectedParent: Identity? = nil
    ) throws -> Record {
        try locked {
            let source = try pathGuard.checkLocation(source)
            let target = try pathGuard.checkWriteLocation(destination)
            let location = try CopyLocation(checked: target)
            let parentIdentity = Identity(try location.parent.info())
            guard expectedParent == nil || expectedParent == parentIdentity else { throw Failure.invalidStore }
            let record = Record(
                version: 1, id: UUID(), session: sessionID, sessionIdentity: Identity(try sessionLock.info()),
                source: source.path,
                destination: target.path, stagingName: stagingName, parent: parentIdentity,
                action: action, phase: .intent, staging: nil, published: nil)
            try validate(record)
            try withStoreLock {
                try validateSessionName()
                try maintainLocked()
                let names = try entryNames()
                guard names.filter({ $0.hasPrefix("record-") }).count < recordLimit else { throw Failure.limit }
                try write(record, replacing: false)
            }
            return record
        }
    }

    func transition(_ id: UUID, to phase: Phase, identity: Identity? = nil) throws -> Record {
        try locked {
            try withStoreLock {
                var record = try read(id)
                guard record.session == sessionID, record.sessionIdentity == Identity(try sessionLock.info()) else {
                    throw Failure.invalidTransition
                }
                try validateSessionName()
                switch (record.phase, phase) {
                case (.intent, .staging):
                    guard let identity else { throw Failure.invalidTransition }
                    record.staging = identity
                case (.staging, .publishing): break
                case (.publishing, .published):
                    guard let identity, identity == record.staging else { throw Failure.invalidTransition }
                    record.published = identity
                case (.intent, .resolved), (.staging, .resolved), (.publishing, .resolved), (.published, .resolved):
                    break
                default: throw Failure.invalidTransition
                }
                record.phase = phase
                try validate(record)
                try write(record, replacing: true)
                if phase == .resolved {
                    try removeMetadata(recordName(id))
                    try sync(root.raw)
                }
                return record
            }
        }
    }

    /// Reads only metadata for records in the explicitly accessed folder.
    /// A candidate is evidence for review, never authorization to remove data.
    func discover(in folder: URL) throws -> [Discovery] {
        try locked {
            let checked = try pathGuard.checkTarget(folder)
            return try withStoreLock {
                let names = try entryNames().filter { $0.hasPrefix("record-") }
                guard names.count <= Self.maxRecords else { throw Failure.limit }
                var result: [Discovery] = []
                for name in names {
                    guard let id = UUID(uuidString: String(name.dropFirst(7))), name == recordName(id) else {
                        throw Failure.malformed
                    }
                    let record = try read(id)
                    guard URL(fileURLWithPath: record.destination).deletingLastPathComponent().path == checked.path
                    else {
                        continue
                    }
                    let status = try ownership(record, folder: checked)
                    result.append(Discovery(record: record, ownership: status))
                }
                return result
            }
        }
    }

    /// Forgets metadata only, and only when the owning session lock can be held.
    func forget(_ id: UUID) throws {
        try locked {
            try withStoreLock {
                let record = try read(id)
                guard record.session != sessionID else { throw Failure.busy }
                let lock = try inactiveLock(record.session, expected: record.sessionIdentity)
                defer { flock(lock.raw, LOCK_UN) }
                try removeMetadata(recordName(id))
                try sync(root.raw)
            }
        }
    }

    private func ownership(_ record: Record, folder: URL) throws -> Ownership {
        if record.session == sessionID { return .active }
        let lock: CopyDescriptor
        do { lock = try inactiveLock(record.session, expected: record.sessionIdentity) } catch Failure.busy {
            return .active
        } catch { return .ambiguous }
        defer { flock(lock.raw, LOCK_UN) }
        if record.phase == .resolved { return .resolved }
        if record.phase == .published { return .published }
        guard record.phase == .staging || record.phase == .publishing, let identity = record.staging else {
            return .ambiguous
        }
        do {
            let destination = try pathGuard.checkWriteLocation(URL(fileURLWithPath: record.destination))
            guard destination.deletingLastPathComponent().path == folder.path else { return .ambiguous }
            let location = try CopyLocation(checked: destination)
            guard Identity(try location.parent.info()) == record.parent else { return .ambiguous }
            let staged = CopyLocation(parent: location.parent, name: record.stagingName, path: destination.path)
            guard Identity(try staged.info()) == identity else { return .ambiguous }
            return .candidate
        } catch { return .ambiguous }
    }

    private func inactiveLock(_ session: UUID, expected: Identity) throws -> CopyDescriptor {
        let name = "session-" + session.uuidString
        let fd = openat(root.raw, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        let lock = try CopyDescriptor(fd, path: name)
        let info = try lock.info()
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o600,
            info.st_nlink == 1, Identity(info) == expected
        else { throw Failure.invalidStore }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        var current = stat()
        guard fstatat(root.raw, name, &current, AT_SYMLINK_NOFOLLOW) == 0, Identity(current) == expected else {
            throw Failure.invalidStore
        }
        return lock
    }

    private func validate(_ record: Record) throws {
        guard record.version == 1, record.source.hasPrefix("/"), record.destination.hasPrefix("/"),
            record.source.utf8.count <= Self.maxPathBytes, record.destination.utf8.count <= Self.maxPathBytes,
            !record.source.utf8.contains(0), !record.destination.utf8.contains(0),
            record.stagingName.hasPrefix(FileEngine.partialPrefix),
            UUID(uuidString: String(record.stagingName.dropFirst(FileEngine.partialPrefix.count))) != nil,
            record.stagingName.utf8.count <= 255, record.parent.kind == UInt32(S_IFDIR),
            record.parent.inode != 0, record.sessionIdentity.kind == UInt32(S_IFREG),
            record.sessionIdentity.inode != 0
        else { throw Failure.malformed }
        switch record.phase {
        case .intent: guard record.staging == nil, record.published == nil else { throw Failure.malformed }
        case .staging, .publishing:
            guard record.staging != nil, record.published == nil else { throw Failure.malformed }
        case .published:
            guard record.staging != nil, record.staging == record.published else { throw Failure.malformed }
        case .resolved: break
        }
        if let identity = record.staging {
            guard identity.inode != 0, [UInt32(S_IFREG), UInt32(S_IFDIR), UInt32(S_IFLNK)].contains(identity.kind),
                identity.device == record.parent.device
            else { throw Failure.malformed }
        }
    }

    private func recordName(_ id: UUID) -> String { "record-" + id.uuidString }

    private func read(_ id: UUID) throws -> Record {
        try readNamed(recordName(id), expectedID: id)
    }

    private func readNamed(_ name: String, expectedID: UUID?) throws -> Record {
        let file = try CopyDescriptor(
            openat(root.raw, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC), path: name)
        let info = try file.info()
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o600,
            info.st_nlink == 1, info.st_size > 0, info.st_size <= Int64(Self.maxRecordBytes)
        else { throw Failure.malformed }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        var interruptions = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(file.raw, $0.baseAddress!.advanced(by: offset), remaining)
            }
            if count < 0 && errno == EINTR && interruptions < 8 {
                interruptions += 1
                continue
            }
            guard count > 0 else { throw Failure.malformed }
            offset += count
        }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: Data(bytes)) } catch { throw Failure.malformed }
        let after = try file.info()
        var named = stat()
        guard fstatat(root.raw, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
            Identity(info) == Identity(after), Identity(info) == Identity(named),
            info.st_size == after.st_size, info.st_size == named.st_size,
            info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
            expectedID == nil || record.id == expectedID
        else { throw Failure.malformed }
        try validate(record)
        return record
    }

    private func write(_ record: Record, replacing: Bool) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maxRecordBytes else { throw Failure.limit }
        try checkEntryLimit()
        let temporary = "tmp-" + sessionID.uuidString + "-" + UUID().uuidString
        let file = try CopyDescriptor(
            openat(root.raw, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600), path: temporary)
        let temporaryIdentity = Identity(try file.info())
        defer { try? removeMetadata(temporary, expected: temporaryIdentity) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            var interruptions = 0
            while offset < bytes.count {
                let count = Darwin.write(file.raw, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR && interruptions < 8 {
                    interruptions += 1
                    continue
                }
                guard count > 0 else { throw Failure.io(errno) }
                offset += count
            }
        }
        try sync(file.raw)
        let result =
            replacing
            ? renameat(root.raw, temporary, root.raw, recordName(record.id))
            : renameatx_np(root.raw, temporary, root.raw, recordName(record.id), UInt32(RENAME_EXCL))
        guard result == 0 else { throw Failure.io(errno) }
        try sync(root.raw)
    }

    /// Reclaims only metadata in the private journal root, while the store lock
    /// is held. A corrupt record stops maintenance before any deletion.
    func maintain() throws {
        try locked { try withStoreLock { try maintainLocked() } }
    }

    private func maintainLocked() throws {
        let names = try entryNames()
        let recordNames = names.filter { $0.hasPrefix("record-") }
        guard recordNames.count <= Self.maxRecords else { throw Failure.limit }
        var records: [Record] = []
        for name in recordNames {
            guard let id = UUID(uuidString: String(name.dropFirst(7))), name == recordName(id) else {
                throw Failure.malformed
            }
            records.append(try read(id))
        }
        var changed = false
        for name in names where name.hasPrefix("session-") {
            let suffix = String(name.dropFirst(8))
            guard let id = UUID(uuidString: suffix), name == "session-" + id.uuidString else { continue }
            guard id != sessionID else { continue }
            let related = records.filter { $0.session == id }
            let fd = openat(root.raw, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let held = try CopyDescriptor(fd, path: name)
            let info = try held.info()
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                info.st_mode & 0o7777 == 0o600, info.st_nlink == 1,
                related.allSatisfy({ $0.sessionIdentity == Identity(info) }),
                flock(fd, LOCK_EX | LOCK_NB) == 0
            else { continue }
            defer { flock(fd, LOCK_UN) }
            var current = stat()
            guard fstatat(root.raw, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                Identity(info) == Identity(current)
            else { continue }
            for record in related where record.phase == .resolved {
                try removeMetadata(recordName(record.id))
                changed = true
            }
            // A temp name contains its owner session and a random UUID. Only
            // clean it while that exact session's lock is held.
            let tempPrefix = "tmp-" + id.uuidString + "-"
            var hasUnverifiedTemporary = false
            for temporary in names where temporary.hasPrefix(tempPrefix) {
                guard UUID(uuidString: String(temporary.dropFirst(tempPrefix.count))) != nil,
                    let candidate = try? readNamed(temporary, expectedID: nil),
                    candidate.session == id, candidate.sessionIdentity == Identity(info)
                else {
                    hasUnverifiedTemporary = true
                    continue
                }
                try removeMetadata(temporary)
                changed = true
            }
            if !hasUnverifiedTemporary && related.allSatisfy({ $0.phase == .resolved }) {
                try removeMetadata(name)
                changed = true
            }
        }
        if changed { try sync(root.raw) }
    }

    private func validateSessionName() throws {
        var named = stat()
        let name = "session-" + sessionID.uuidString
        guard fstatat(root.raw, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
            Identity(named) == Identity(try sessionLock.info())
        else { throw Failure.invalidStore }
    }

    private func removeMetadata(_ name: String, expected: Identity? = nil) throws {
        let fd = openat(root.raw, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return }
        let file = try CopyDescriptor(fd, path: name)
        let info = try file.info()
        var named = stat()
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
            info.st_mode & 0o7777 == 0o600, info.st_nlink == 1,
            fstatat(root.raw, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
            Identity(info) == Identity(named), expected == nil || expected == Identity(info)
        else { throw Failure.invalidStore }
        guard unlinkat(root.raw, name, 0) == 0 else { throw Failure.io(errno) }
    }

    private func sync(_ fd: Int32) throws {
        for _ in 0..<8 {
            if fsync(fd) == 0 { return }
            if errno != EINTR { throw Failure.io(errno) }
        }
        throw Failure.io(EINTR)
    }

    private func entryNames() throws -> [String] { try Self.names(in: root.raw) }

    private static func names(in directory: Int32) throws -> [String] {
        let fd = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0, let stream = fdopendir(fd) else {
            if fd >= 0 { close(fd) }
            throw Failure.io(errno)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw Failure.io(errno) }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            names.append(name)
            guard names.count <= Self.maxEntries else { throw Failure.limit }
        }
        return names
    }

    private func checkEntryLimit() throws {
        // Leave room for one temporary file and one later maintenance session.
        guard try entryNames().count < Self.maxEntries - 2 else { throw Failure.limit }
    }

    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        let checked = try pathGuard.checkWriteLocation(rootURL)
        guard checked.path == rootURL.path else { throw Failure.invalidStore }
        let current = try CopyDescriptor(
            Darwin.open(checked.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC), path: checked.path)
        guard Identity(try current.info()) == Identity(try root.info()) else { throw Failure.invalidStore }
        let file = try CopyDescriptor(
            openat(root.raw, "store.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600), path: "store.lock")
        let info = try file.info()
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o600,
            info.st_nlink == 1
        else { throw Failure.invalidStore }
        guard flock(file.raw, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        defer { flock(file.raw, LOCK_UN) }
        var currentLock = stat()
        guard fstatat(root.raw, "store.lock", &currentLock, AT_SYMLINK_NOFOLLOW) == 0,
            Identity(currentLock) == Identity(info)
        else { throw Failure.invalidStore }
        return try body()
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        guard mutex.try() else { throw Failure.busy }
        defer { mutex.unlock() }
        return try body()
    }
}
