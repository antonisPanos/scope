import Foundation

/// One copy traverses pinned directories and never follows a final link.
/// Metadata is deferred until publication, so cancelled partials stay removable.
struct CopyJob {
    let progressHandler: (@Sendable (CopyProgress) -> Void)?
    var state = CopyProgress(bytesDone: 0, bytesTotal: 0, itemsDone: 0, itemsTotal: 0, currentItem: "")
    var partialIdentity: stat?
    /// Keeps the original staged root pinned across metadata and publication.
    var partialDescriptor: CopyDescriptor?

    private struct Deferred {
        let relative: String
        let source: stat
        let destination: stat
        let directory: Bool
        let flags: UInt32
        let hasACL: Bool
    }
    private var deferred: [Deferred] = []
    let control: OperationControl?
    let readFault: (@Sendable (String) -> Int32?)?
    let writeFault: (@Sendable (String, Int64) -> Int32?)?
    let syncFault: CopySyncFault?
    let testOptions: FileEngine.CopyTestOptions
    var rootCreated: ((stat) throws -> Void)?

    init(
        progress: (@Sendable (CopyProgress) -> Void)?, control: OperationControl?,
        readFault: (@Sendable (String) -> Int32?)? = nil, writeFault: (@Sendable (String, Int64) -> Int32?)? = nil,
        syncFault: CopySyncFault? = nil,
        testOptions: FileEngine.CopyTestOptions = .init(),
        rootCreated: ((stat) throws -> Void)? = nil
    ) {
        progressHandler = progress
        self.control = control
        self.readFault = readFault
        self.writeFault = writeFault
        self.syncFault = syncFault
        self.testOptions = testOptions
        self.rootCreated = rootCreated
    }

    /// Counts what a copy of `source` will write. With `rejectingUnsupported`,
    /// it fails on the first item a copy can't reproduce, before anything is written.
    mutating func measure(_ source: CopyLocation, rejectingUnsupported: Bool = false) throws {
        try Task.checkCancellation()
        let info = try source.info()
        state.itemsTotal += 1
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            let directory = try source.open(O_RDONLY | O_DIRECTORY, matching: info)
            for name in try CopyLocation.names(in: directory, path: source.path) {
                try measure(source.child(name, in: directory), rejectingUnsupported: rejectingUnsupported)
            }
        case S_IFREG:
            state.bytesTotal += Int64(info.st_size)
        default:
            if rejectingUnsupported { try Self.checkCopyable(info, path: source.path) }
        }
    }

    /// Folders, files and symlinks are copied. Named pipes, sockets and device
    /// files are not, so a copy that meets one fails rather than publishing
    /// a tree that silently lacks it.
    static func checkCopyable(_ info: stat, path: String) throws {
        switch info.st_mode & S_IFMT {
        case S_IFDIR, S_IFREG, S_IFLNK: return
        case S_IFIFO: throw FileEngineError.unsupportedItem(path, kind: "a named pipe (FIFO)")
        case S_IFSOCK: throw FileEngineError.unsupportedItem(path, kind: "a socket")
        case S_IFCHR, S_IFBLK: throw FileEngineError.unsupportedItem(path, kind: "a device file")
        default: throw FileEngineError.unsupportedItem(path, kind: "a special file")
        }
    }

    mutating func copy(from source: CopyLocation, to destination: CopyLocation, relative: String) throws {
        try Task.checkCancellation()
        let info = try source.info()
        state.currentItem = relative
        report()
        try Task.checkCancellation()
        try control?.waitWhilePaused()
        let directory = info.st_mode & S_IFMT == S_IFDIR
        let link = info.st_mode & S_IFMT == S_IFLNK
        try Self.checkCopyable(info, path: source.path)
        // The check and open refer to the same object. O_NONBLOCK also keeps
        // a regular file swapped for a pipe from hanging before fstat checks it.
        let input = try source.open(directory ? O_RDONLY | O_DIRECTORY : link ? O_SYMLINK : O_RDONLY, matching: info)
        let output: CopyDescriptor
        if directory {
            guard mkdirat(destination.parent.raw, destination.name, 0o700) == 0 else {
                throw FileEngineError.posix("Create folder", destination.path)
            }
            let created = try destination.info()
            if relative.isEmpty { partialIdentity = created }
            output = try destination.open(O_RDONLY | O_DIRECTORY, matching: created)
            if relative.isEmpty {
                partialDescriptor = output
                try rootCreated?(output.info())
            }
            for name in try CopyLocation.names(in: input, path: source.path).sorted() {
                try copy(
                    from: source.child(name, in: input), to: destination.child(name, in: output),
                    relative: relative.isEmpty ? name : relative + "/" + name)
            }
            try CopySync.sync(output.raw, path: destination.path, point: .directory, fault: syncFault)
        } else if link {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlinkat(source.parent.raw, source.name, &buffer, buffer.count - 1)
            guard count >= 0 else { throw FileEngineError.posix("Read link", source.path) }
            guard CopyLocation.same(try source.info(), info) else {
                throw FileEngineError.posix("Link changed while copying", source.path, EBUSY)
            }
            buffer[count] = 0
            guard symlinkat(buffer, destination.parent.raw, destination.name) == 0 else {
                throw FileEngineError.posix("Create link", destination.path)
            }
            let created = try destination.info()
            if relative.isEmpty { partialIdentity = created }
            output = try destination.open(O_SYMLINK, matching: created)
            if relative.isEmpty {
                partialDescriptor = output
                try rootCreated?(output.info())
            }
        } else {
            if let code = readFault?(source.path) { throw FileEngineError.posix("Read", source.path, code) }
            let cloned =
                !testOptions.disableCloning && info.st_flags == 0
                && fclonefileat(input.raw, destination.parent.raw, destination.name, UInt32(CLONE_NOOWNERCOPY)) == 0
            if cloned {
                output = try destination.open(O_RDONLY)
                if relative.isEmpty {
                    partialIdentity = try output.info()
                    partialDescriptor = output
                    try rootCreated?(output.info())
                }
                clearACL(output)
                state.bytesDone += Int64(info.st_size)
                report()
            } else {
                output = try CopyDescriptor(
                    openat(
                        destination.parent.raw, destination.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        0o600),
                    path: destination.path)
                if relative.isEmpty {
                    partialIdentity = try output.info()
                    partialDescriptor = output
                    try rootCreated?(output.info())
                }
                try copyData(input, output, source: source.path, destination: destination.path, info: info)
            }
            if relative.isEmpty { partialIdentity = try output.info() }
            testOptions.boundary?(
                .beforeMetadata, URL(fileURLWithPath: source.path), URL(fileURLWithPath: destination.path))
            guard fcopyfile(input.raw, output.raw, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR)) == 0 else {
                throw FileEngineError.posix("Copy attributes", destination.path)
            }
            if info.st_flags != 0 { _ = fchflags(output.raw, 0) }
            try Self.copyTimes(info, to: output)
            // Also flush cloned files, and metadata written after copyData.
            try CopySync.sync(output.raw, path: destination.path, point: .file, fault: syncFault)
        }
        let flags = FileEngine.settableFlags(info.st_flags)
        let hasACL = Self.hasACL(input)
        if directory || link || flags != 0 || hasACL {
            deferred.append(
                Deferred(
                    relative: relative, source: info, destination: try output.info(), directory: directory,
                    flags: flags, hasACL: hasACL))
        }
        state.itemsDone += 1
        report()
    }

    private mutating func copyData(
        _ input: CopyDescriptor, _ output: CopyDescriptor, source: String, destination: String, info: stat
    ) throws {
        let size = off_t(info.st_size)
        let sizeLimit = max(1, min(testOptions.chunkSize, FileEngine.chunkSize))
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: sizeLimit, alignment: 16)
        defer { buffer.deallocate() }
        let compressed = info.st_flags & UInt32(UF_COMPRESSED) != 0
        if !compressed, Int64(info.st_blocks) * 512 < Int64(size) {
            var offset: off_t = 0
            while offset < size {
                let start = lseek(input.raw, offset, SEEK_DATA)
                if start < 0 {
                    guard errno == ENXIO else { throw FileEngineError.posix("Read", source) }
                    break
                }
                var end = lseek(input.raw, start, SEEK_HOLE)
                if end < 0 || end > size { end = size }
                state.bytesDone += Int64(start - offset)
                try copyRange(
                    input.raw, output.raw, from: start, to: end, buffer: buffer, source: source,
                    destination: destination)
                offset = end
            }
            state.bytesDone += Int64(max(0, size - offset))
            guard ftruncate(output.raw, size) == 0 else { throw FileEngineError.posix("Write", destination) }
        } else {
            try copyRange(
                input.raw, output.raw, from: 0, to: nil, buffer: buffer, source: source, destination: destination)
        }
    }

    private mutating func copyRange(
        _ input: Int32, _ output: Int32, from start: off_t, to end: off_t?,
        buffer: UnsafeMutableRawPointer, source: String, destination: String
    ) throws {
        var offset = start
        while end.map({ offset < $0 }) ?? true {
            try Task.checkCancellation()
            try control?.waitWhilePaused()
            let chunkSize = max(1, min(testOptions.chunkSize, FileEngine.chunkSize))
            let wanted = end.map { min(chunkSize, Int($0 - offset)) } ?? chunkSize
            let count = pread(input, buffer, wanted, offset)
            if count < 0 {
                if errno == EINTR { continue }
                throw FileEngineError.posix("Read", source)
            }
            if count == 0 { break }
            if let code = writeFault?(destination, Int64(offset)) {
                throw FileEngineError.posix("Write", destination, code)
            }
            var written = 0
            while written < count {
                let result = pwrite(output, buffer + written, count - written, offset + off_t(written))
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw FileEngineError.posix("Write", destination) }
                written += result
            }
            offset += off_t(count)
            state.bytesDone += Int64(count)
            report()
        }
    }

    func finish(source: CopyLocation, destination: CopyLocation) throws {
        for entry in deferred {
            // Do not apply metadata from a changed source. Opening the
            // destination is mandatory: its final sync must not be skipped.
            let link = entry.source.st_mode & S_IFMT == S_IFLNK
            let flags = link ? O_SYMLINK : O_RDONLY
            let output = try destination.descendant(entry.relative).open(flags, matching: entry.destination)
            if let input = try? source.descendant(entry.relative).open(flags, matching: entry.source) {
                let metadata = entry.directory || link ? COPYFILE_METADATA : COPYFILE_ACL
                if entry.directory || link || entry.hasACL {
                    _ = fcopyfile(input.raw, output.raw, nil, copyfile_flags_t(metadata))
                    if entry.directory || link { try? Self.copyTimes(entry.source, to: output) }
                }
                if entry.flags != 0 { _ = fchflags(output.raw, entry.flags) }
            }
            // Symlink descriptors cannot be fsynced; their containing folder
            // is synced after its entries and metadata have been applied.
            if entry.source.st_mode & S_IFMT != S_IFLNK {
                try CopySync.sync(
                    output.raw, path: destination.path, point: entry.directory ? .directory : .file, fault: syncFault)
            }
        }
    }

    private static func copyTimes(_ info: stat, to descriptor: CopyDescriptor) throws {
        var times = [info.st_atimespec, info.st_mtimespec]
        guard futimens(descriptor.raw, &times) == 0 else { throw FileEngineError.posix("Set dates", "open copy") }
    }

    private static func hasACL(_ descriptor: CopyDescriptor) -> Bool {
        guard let acl = acl_get_fd_np(descriptor.raw, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0
    }

    private func clearACL(_ descriptor: CopyDescriptor) {
        guard let empty = acl_init(0) else { return }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        _ = acl_set_fd_np(descriptor.raw, empty, ACL_TYPE_EXTENDED)
    }

    private func report() { progressHandler?(state) }
}
