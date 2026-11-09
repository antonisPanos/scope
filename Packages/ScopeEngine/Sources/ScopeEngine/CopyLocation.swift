import Foundation

/// An optional fault at a copy's sync boundary. Returning nil performs the syscall.
enum CopySyncPoint: Sendable, Equatable {
    case openParent, directory, file, parent
}

typealias CopySyncFault = @Sendable (CopySyncPoint, String) -> Int32?

enum CopySync {
    static func sync(_ fd: Int32, path: String, point: CopySyncPoint, fault: CopySyncFault?) throws {
        while true {
            let code: Int32
            if let injected = fault?(point, path) {
                code = injected
            } else if fsync(fd) == 0 {
                return
            } else {
                code = errno
            }
            if code == EINTR { continue }
            // Some Darwin filesystems do not implement directory fsync.
            // This fallback says nothing about physical-media durability.
            if (point == .directory || point == .parent) && (code == EINVAL || code == ENOTSUP) { return }
            throw FileEngineError.posix("Sync", path, code)
        }
    }
}

/// A descriptor owns the object opened, even if another process changes its name.
final class CopyDescriptor {
    let raw: Int32

    init(_ raw: Int32, path: String) throws {
        guard raw >= 0 else { throw FileEngineError.posix("Open", path) }
        self.raw = raw
    }

    deinit { close(raw) }

    func info() throws -> stat {
        var value = stat()
        guard fstat(raw, &value) == 0 else { throw FileEngineError.posix("Read open item", "descriptor") }
        return value
    }
}

/// Copy traversal uses one component at a time relative to an open directory.
/// Display paths are only for progress and errors, never the I/O authority.
struct CopyLocation {
    let parent: CopyDescriptor
    let name: String
    let path: String

    init(checked url: URL) throws {
        let directory = url.deletingLastPathComponent().path
        // PathGuard has already canonicalized this absolute path. Refuse
        // every symlink if any component changed before the kernel opens it.
        parent = try CopyDescriptor(Darwin.open(directory, O_SEARCH | O_NOFOLLOW_ANY | O_CLOEXEC), path: directory)
        name = url.lastPathComponent
        path = url.path
    }

    init(parent: CopyDescriptor, name: String, path: String) {
        self.parent = parent
        self.name = name
        self.path = path
    }

    func info() throws -> stat {
        var value = stat()
        guard fstatat(parent.raw, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw FileEngineError.posix("Read", path)
        }
        return value
    }

    func open(_ flags: Int32, matching expected: stat? = nil) throws -> CopyDescriptor {
        // O_SYMLINK opens the link itself on Darwin; combining it with
        // O_NOFOLLOW instead refuses a dangling link with ELOOP.
        let noFollow = flags & O_SYMLINK == 0 ? O_NOFOLLOW : 0
        let descriptor = try CopyDescriptor(
            openat(parent.raw, name, flags | noFollow | O_NONBLOCK | O_CLOEXEC), path: path)
        if let expected, !Self.same(try descriptor.info(), expected) {
            throw FileEngineError.posix("Item changed while copying", path, EBUSY)
        }
        return descriptor
    }

    func child(_ name: String, in directory: CopyDescriptor) -> CopyLocation {
        CopyLocation(parent: directory, name: name, path: path + "/" + name)
    }

    /// Reopens a descendant beneath this location without following links.
    func descendant(_ relative: String) throws -> CopyLocation {
        guard !relative.isEmpty else { return self }
        var location = self
        for component in relative.split(separator: "/") {
            let directory = try location.open(O_SEARCH | O_DIRECTORY)
            location = location.child(String(component), in: directory)
        }
        return location
    }

    func validateParent(pathGuard: PathGuard) throws {
        let checked = try pathGuard.checkWriteLocation(URL(fileURLWithPath: path))
        let current = try CopyLocation(checked: checked)
        guard checked.path == path, Self.same(try parent.info(), try current.parent.info()) else {
            throw FileEngineError.posix("Destination changed while copying", path, EBUSY)
        }
    }

    func syncParent() {
        let directory = openat(parent.raw, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { return }
        defer { close(directory) }
        _ = fsync(directory)
    }

    /// Unlike the archive compatibility helper above, copy finalization must
    /// surface open and sync failures before a move can retire its source.
    func syncParent(fault: CopySyncFault?) throws {
        let directory: Int32
        while true {
            if let code = fault?(.openParent, path) {
                if code == EINTR { continue }
                throw FileEngineError.posix("Open folder for sync", path, code)
            }
            let fd = openat(parent.raw, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if fd >= 0 {
                directory = fd
                break
            }
            if errno == EINTR { continue }
            throw FileEngineError.posix("Open folder for sync", path)
        }
        defer { close(directory) }
        try CopySync.sync(directory, path: path, point: .parent, fault: fault)
    }

    static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode & S_IFMT == b.st_mode & S_IFMT
    }

    func linkTarget() throws -> String {
        let before = try info()
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlinkat(parent.raw, name, &buffer, buffer.count - 1)
        guard count >= 0 else { throw FileEngineError.posix("Read link", path) }
        guard Self.same(before, try info()) else { throw FileEngineError.posix("Link changed", path, EBUSY) }
        return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func names(in directory: CopyDescriptor, path: String) throws -> [String] {
        // Opening "." gives readdir its own offset, rather than sharing an
        // offset through dup with a later traversal or cleanup.
        let reader = openat(directory.raw, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard reader >= 0 else { throw FileEngineError.posix("Read folder", path) }
        guard let stream = fdopendir(reader) else {
            close(reader)
            throw FileEngineError.posix("Read folder", path)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw FileEngineError.posix("Read folder", path) }
                return names
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    /// Removes only the unpublished partial, through its original parent.
    /// A replaced root is left alone, and symlinks are always unlinked as links.
    func removePartial(matching expected: stat?) throws {
        guard let current = try? info() else { return }
        guard let expected, Self.same(current, expected) else {
            throw FileEngineError.posix("Partial item changed", path, EBUSY)
        }
        let directory = current.st_mode & S_IFMT == S_IFDIR
        let flags = directory ? O_RDONLY | O_DIRECTORY : current.st_mode & S_IFMT == S_IFLNK ? O_SYMLINK : O_EVTONLY
        let item = try open(flags, matching: current)
        // Metadata copying may itself fail after applying a flag or ACL.
        // Clear protections through the owned descriptor before cleanup.
        _ = fchflags(item.raw, 0)
        if let acl = acl_init(0) {
            _ = acl_set_fd_np(item.raw, acl, ACL_TYPE_EXTENDED)
            acl_free(UnsafeMutableRawPointer(acl))
        }
        if directory {
            _ = fchmod(item.raw, 0o700)
            for name in try Self.names(in: item, path: path) {
                let child = child(name, in: item)
                try child.removePartial(matching: child.info())
            }
        }
        guard Self.same(current, try info()) else { throw FileEngineError.posix("Partial item changed", path, EBUSY) }
        guard unlinkat(parent.raw, name, directory ? AT_REMOVEDIR : 0) == 0 else {
            throw FileEngineError.posix("Remove partial", path)
        }
    }

    func renameExclusively(to name: String, isDirectory: Bool) -> Bool {
        renameExclusively(into: parent, as: name, isDirectory: isDirectory)
    }

    /// Moves this item into `folder` as `name`, only if nothing has that name.
    /// FAT and exFAT can't rename exclusively, so there the name is first
    /// claimed with an exclusive create, and only that placeholder is replaced.
    func renameExclusively(into folder: CopyDescriptor, as name: String, isDirectory: Bool) -> Bool {
        if renameatx_np(parent.raw, self.name, folder.raw, name, UInt32(RENAME_EXCL)) == 0 { return true }
        guard errno == ENOTSUP || errno == EINVAL else { return false }
        if isDirectory {
            guard mkdirat(folder.raw, name, 0o700) == 0 else { return false }
        } else {
            let placeholder = openat(folder.raw, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard placeholder >= 0 else { return false }
            close(placeholder)
        }
        if renameat(parent.raw, self.name, folder.raw, name) == 0 { return true }
        let failure = errno
        _ = unlinkat(folder.raw, name, isDirectory ? AT_REMOVEDIR : 0)
        errno = failure
        return false
    }
}

/// Keeps a merge directory open across prompts and rejects path substitution.
/// Child operations must still use or verify this descriptor at their own I/O boundary.
struct MergeDirectory {
    let url: URL
    private let location: CopyLocation
    private let descriptor: CopyDescriptor
    private let identity: stat
    private let writable: Bool

    init(_ url: URL, pathGuard: PathGuard, writable: Bool) throws {
        let checked = try writable ? pathGuard.checkWriteLocation(url) : pathGuard.checkLocation(url)
        let location = try CopyLocation(checked: checked)
        let identity = try location.info()
        guard identity.st_mode & S_IFMT == S_IFDIR else {
            throw FileEngineError.posix("Open merge folder", checked.path, ENOTDIR)
        }
        self.url = checked
        self.location = location
        self.identity = identity
        self.descriptor = try location.open(O_RDONLY | O_DIRECTORY, matching: identity)
        self.writable = writable
    }

    func validate(pathGuard: PathGuard) throws {
        let checked = try writable ? pathGuard.checkWriteLocation(url) : pathGuard.checkLocation(url)
        let current = try CopyLocation(checked: checked)
        guard checked.path == url.path,
            CopyLocation.same(try descriptor.info(), identity),
            CopyLocation.same(try location.info(), identity),
            CopyLocation.same(try current.info(), identity),
            CopyLocation.same(try location.parent.info(), try current.parent.info())
        else { throw FileEngineError.posix("Merge folder changed", url.path, EBUSY) }
    }

    func names(pathGuard: PathGuard) throws -> [String] {
        try validate(pathGuard: pathGuard)
        return try CopyLocation.names(in: descriptor, path: url.path).sorted()
    }

    func validateChildParent(_ parent: CopyDescriptor) throws {
        guard CopyLocation.same(try descriptor.info(), try parent.info()) else {
            throw FileEngineError.posix("Merge folder changed", url.path, EBUSY)
        }
    }
}
