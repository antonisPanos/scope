import Foundation

/// Checks a copy or move against its destination before anything is written:
/// names the destination's file system can't store, files over its size
/// limit, and free space. Finding these partway through would leave the job
/// half done. Running out of space mid-copy is still handled, as a backstop.
extension FileEngine {
    /// What a destination's file system allows.
    struct DestinationLimits: Equatable {
        /// The file system's name as `statfs` reports it ("apfs", "msdos", "exfat").
        var fileSystem: String
        /// The volume's name, for messages.
        var volumeName: String
        var freeBytes: Int64?
        /// The largest file it can hold; nil when there is no practical limit.
        var maxFileSize: Int64?
        /// Whether names are checked against FAT's rules (FAT and exFAT).
        var usesFATNames: Bool
        /// Whether files copied within it can be clones that take no space.
        var clones: Bool

        init(fileSystem: String, volumeName: String, freeBytes: Int64?) {
            self.fileSystem = fileSystem
            self.volumeName = volumeName
            self.freeBytes = freeBytes
            maxFileSize = fileSystem == "msdos" ? 4 * 1024 * 1024 * 1024 - 1 : nil
            usesFATNames = fileSystem == "msdos" || fileSystem == "exfat"
            clones = fileSystem == "apfs"
        }

        static func of(_ folder: URL) -> DestinationLimits? {
            var info = statfs()
            guard statfs(folder.path, &info) == 0 else { return nil }
            let type = withUnsafeBytes(of: info.f_fstypename) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            let mount = withUnsafeBytes(of: info.f_mntonname) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            let name =
                (try? URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeLocalizedNameKey]))?
                .volumeLocalizedName ?? (mount as NSString).lastPathComponent
            return DestinationLimits(
                fileSystem: type, volumeName: name.isEmpty ? mount : name,
                freeBytes: Int64(info.f_bavail) * Int64(info.f_bsize))
        }
    }

    /// Room kept free beyond the copy itself, for folders and metadata.
    static let copyHeadroom: Int64 = 16 * 1024 * 1024

    /// Throws the first reason the items can't go into `destination`.
    /// Items that will only be renamed (a move on one disk) need no space.
    func preflight(_ sources: [URL], into destination: URL, moving: Bool) throws {
        guard let limits = DestinationLimits.of(destination) else { return }
        guard let device = Self.lstatInfo(destination.path)?.st_dev else { return }
        var needed: Int64 = 0
        for source in sources {
            try Task.checkCancellation()
            let sameDisk = Self.lstatInfo(source.path)?.st_dev == device
            if moving && sameDisk { continue }
            var scan = PreflightScan(limits: limits)
            try scan.visit(source.path)
            if let name = scan.badName { throw OperationError.nameNotAllowed(name, volume: limits.volumeName) }
            if let file = scan.tooLarge { throw OperationError.fileTooLarge(file, volume: limits.volumeName) }
            // A copy within one APFS volume is a clone and takes no space.
            if !(sameDisk && limits.clones) { needed += scan.bytes }
        }
        if let free = limits.freeBytes, needed > 0, needed + Self.copyHeadroom > free {
            throw OperationError.notEnoughSpace(needed: needed, available: free, volume: limits.volumeName)
        }
    }

    /// Characters FAT and exFAT can't store in a name.
    static let fatForbidden = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)

    static func isStorableOnFAT(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf16.count <= 255 else { return false }
        guard name.unicodeScalars.allSatisfy({ !fatForbidden.contains($0) }) else { return false }
        // Names can't end in a space or a dot there.
        return !(name.hasSuffix(" ") || name.hasSuffix("."))
    }
}

/// One walk over an item: its size, and the first name or file the
/// destination can't take.
private struct PreflightScan {
    let limits: FileEngine.DestinationLimits
    var bytes: Int64 = 0
    var badName: String?
    var tooLarge: String?

    init(limits: FileEngine.DestinationLimits) {
        self.limits = limits
    }

    mutating func visit(_ path: String) throws {
        guard badName == nil, tooLarge == nil else { return }
        try Task.checkCancellation()
        let name = (path as NSString).lastPathComponent
        if limits.usesFATNames, !FileEngine.isStorableOnFAT(name) {
            badName = name
            return
        }
        guard let info = FileEngine.lstatInfo(path) else { return }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            for child in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                try visit(path + "/" + child)
            }
        case S_IFREG:
            let size = Int64(info.st_size)
            if let limit = limits.maxFileSize, size > limit {
                tooLarge = name
                return
            }
            bytes += size
        default:
            break
        }
    }
}
