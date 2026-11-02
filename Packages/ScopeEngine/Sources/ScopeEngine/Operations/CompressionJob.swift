import Foundation

/// Traversal and metadata stay in the guarded parent. Only plain entry
/// descriptions and bounded data chunks reach the compression codec.
struct CompressionJob {
    let writer: any ArchiveWriting
    let format: ArchiveFormat
    let control: OperationControl
    let budget: ArchiveWriteBudget
    private(set) var quarantine: [String: Any]?

    mutating func add(_ source: CopyLocation, as name: String) throws {
        try Task.checkCancellation()
        try control.waitWhilePaused()
        let info = try source.info()
        control.update { $0.currentItem = name }
        let entry = ArchiveEntry(
            name: name, kind: .file, permissions: UInt16(info.st_mode & 0o777),
            modified: Int64(info.st_mtimespec.tv_sec), size: Int64(info.st_size))
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            let directory = try source.open(O_RDONLY | O_DIRECTORY, matching: info)
            try metadata(source, descriptor: directory, name: name, info: info)
            var header = entry
            header.kind = .directory
            try beginEntry(header)
            try writer.finishEntry()
            for child in try CopyLocation.names(in: directory, path: source.path).sorted() where child != ".DS_Store" {
                try add(source.child(child, in: directory), as: name + "/" + child)
            }
        case S_IFLNK:
            var header = entry
            header.kind = .symlink(to: try source.linkTarget())
            guard CopyLocation.same(try source.info(), info) else { throw changed(source.path) }
            try beginEntry(header)
            try writer.finishEntry()
        case S_IFREG:
            let input = try source.open(O_RDONLY, matching: info)
            try metadata(source, descriptor: input, name: name, info: info)
            try beginEntry(entry)
            try contents(input, info: info, path: source.path)
            try writer.finishEntry()
        default:
            throw OperationError.archive("“\(name)” is not a supported file type for compression.")
        }
        control.update { $0.itemsDone += 1 }
    }

    private func contents(_ input: CopyDescriptor, info: stat, path: String) throws {
        var offset: Int64 = 0
        while offset < info.st_size {
            try Task.checkCancellation()
            try control.waitWhilePaused()
            let size = min(FileEngine.chunkSize, Int(info.st_size - offset))
            var data = Data(count: size)
            let count = data.withUnsafeMutableBytes { pread(input.raw, $0.baseAddress, size, off_t(offset)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw changed(path) }
            data.count = count
            try writer.writeData(data)
            offset += Int64(count)
            control.update { $0.bytesDone += Int64(count) }
        }
        let after = try input.info()
        guard after.st_size == info.st_size, after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
            after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec
        else { throw changed(path) }
    }

    private mutating func metadata(_ source: CopyLocation, descriptor: CopyDescriptor, name: String, info: stat) throws
    {
        var hasACL = false
        if let acl = acl_get_fd_np(descriptor.raw, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var first: acl_entry_t?
            hasACL = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &first) == 0
        }
        guard !hasACL, FileEngine.settableFlags(info.st_flags) == 0 else {
            throw OperationError.archive(
                "“\(name)” has access rules or file flags this archive cannot preserve. No archive was kept.")
        }
        if quarantine == nil, fgetxattr(descriptor.raw, "com.apple.quarantine", nil, 0, 0, 0) > 0 {
            guard CopyLocation.same(try source.info(), info) else { throw changed(source.path) }
            quarantine = try URL(fileURLWithPath: source.path).resourceValues(forKeys: [.quarantinePropertiesKey])
                .quarantineProperties
            guard CopyLocation.same(try source.info(), info) else { throw changed(source.path) }
        }
        let attributes = try ArchiveAttributes.read(descriptor.raw)
        guard !attributes.isEmpty else { return }
        let data = try AppleDouble.encode(attributes)
        let path = name as NSString
        let parent = path.deletingLastPathComponent
        let sidecar = (parent.isEmpty ? "" : parent + "/") + "._" + path.lastPathComponent
        try beginEntry(
            ArchiveEntry(
                name: format == .tarGz ? sidecar : "__MACOSX/" + sidecar, kind: .file,
                permissions: 0o600, size: Int64(data.count)))
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            try control.waitWhilePaused()
            let end = offset + min(FileEngine.chunkSize, data.count - offset)
            try writer.writeData(data.subdata(in: offset..<end))
            offset = end
        }
        try writer.finishEntry()
    }

    private func changed(_ path: String) -> OperationError {
        .archive(
            "“\(URL(fileURLWithPath: path).lastPathComponent)” changed while it was being compressed. No archive was kept."
        )
    }

    private func beginEntry(_ entry: ArchiveEntry) throws {
        try budget.authorize(entry)
        try writer.beginEntry(entry)
    }
}
