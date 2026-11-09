import Foundation

/// A bounded list of destination incompatibilities. Paths include the selected
/// item's name, so entries from different selected folders remain distinguishable.
public struct PreflightReport: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case invalidName
        case fileTooLarge(limit: Int64)
        case symbolicLinksUnsupported
        case symbolicLinksUnknown
    }

    public struct Entry: Equatable, Sendable {
        public let path: String
        public let reason: Reason
    }

    static let entryLimit = 20
    public let volume: String
    public private(set) var entries: [Entry] = []
    public private(set) var totalCount = 0
    public var omittedCount: Int { totalCount - entries.count }

    init(volume: String) { self.volume = volume }

    mutating func add(path: String, reason: Reason) {
        if totalCount < Int.max { totalCount += 1 }
        if entries.count < Self.entryLimit { entries.append(Entry(path: path, reason: reason)) }
    }

    var description: String {
        let details = entries.map { entry in
            let reason: String
            switch entry.reason {
            case .invalidName: reason = "name is not supported"
            case .fileTooLarge(let limit): reason = "file exceeds the \(OperationError.bytes(limit)) limit"
            case .symbolicLinksUnsupported: reason = "symbolic links are not supported"
            case .symbolicLinksUnknown: reason = "symbolic link support could not be confirmed"
            }
            return "• \(entry.path.debugDescription): \(reason)"
        }.joined(separator: "\n")
        let omitted = omittedCount > 0 ? "\n\(omittedCount) more incompatibilities not shown." : ""
        return "Can't copy to “\(volume)” (\(totalCount) incompatibilities):\n\(details)\(omitted)\n"
            + "Nothing was copied. Choose a compatible destination or remove the incompatible items and try again."
    }
}

/// Checks a copy or move against its destination before anything is written:
/// names the destination's file system can't store, files over its size
/// limit, and free space. Finding these partway through would leave the job
/// half done. Running out of space mid-copy is still handled, as a backstop.
extension FileEngine {
    /// What a destination's file system allows.
    struct DestinationLimits: Equatable, Sendable {
        enum Support: Equatable, Sendable { case supported, unsupported, unknown }
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
        /// Unknown is kept separate from supported: a link cannot safely be planned on a guess.
        var symbolicLinks: Support

        init(fileSystem: String, volumeName: String, freeBytes: Int64?) {
            self.fileSystem = fileSystem
            self.volumeName = volumeName
            self.freeBytes = freeBytes
            maxFileSize = fileSystem == "msdos" ? 4 * 1024 * 1024 * 1024 - 1 : nil
            usesFATNames = fileSystem == "msdos" || fileSystem == "exfat"
            clones = fileSystem == "apfs"
            symbolicLinks = .unknown
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
            let (freeBytes, overflow) = Int64(clamping: info.f_bavail)
                .multipliedReportingOverflow(by: Int64(info.f_bsize))
            var limits = DestinationLimits(
                fileSystem: type, volumeName: name.isEmpty ? mount : name,
                freeBytes: overflow ? Int64.max : freeBytes)
            if let supports = (try? folder.resourceValues(forKeys: [.volumeSupportsSymbolicLinksKey]))?
                .volumeSupportsSymbolicLinks
            {
                limits.symbolicLinks = supports ? .supported : .unsupported
            }
            return limits
        }
    }

    /// Shared injection seam: #174 can supply capabilities without changing path checks.
    typealias DestinationCapabilitiesProvider = @Sendable (URL) throws -> DestinationLimits

    /// Room kept free beyond the copy itself, for folders and metadata.
    static let copyHeadroom: Int64 = 16 * 1024 * 1024

    /// Refuses the entire batch if a known incompatibility or uncertain link capability is found.
    /// Items that will only be renamed (a move on one disk) need no space.
    func preflight(
        _ sources: [URL], into destination: URL, moving: Bool,
        capabilities: DestinationCapabilitiesProvider = { folder in
            guard let limits = DestinationLimits.of(folder) else {
                throw FileEngineError.posix("Check destination", folder.path)
            }
            return limits
        }
    ) throws {
        let checkedDestination = try pathGuard.checkWriteLocation(destination)
        let limits = try capabilities(checkedDestination)
        let device = try CopyLocation(checked: checkedDestination).info().st_dev
        var needed: Int64 = 0
        var report = PreflightReport(volume: limits.volumeName)
        for source in sources {
            try Task.checkCancellation()
            let checkedSource = try pathGuard.checkLocation(source)
            let location = try CopyLocation(checked: checkedSource)
            let sameDisk = try location.info().st_dev == device
            if moving && sameDisk { continue }
            var scan = PreflightScan(limits: limits, report: report)
            try scan.visit(location, relative: checkedSource.lastPathComponent)
            report = scan.report
            // A copy within one APFS volume is a clone and takes no space.
            if !(sameDisk && limits.clones) { needed = Self.saturatingAdd(needed, scan.bytes) }
        }
        if report.totalCount > 0 { throw OperationError.incompatibleDestination(report) }
        if let free = limits.freeBytes, needed > 0, Self.saturatingAdd(needed, Self.copyHeadroom) > free {
            throw OperationError.notEnoughSpace(needed: needed, available: free, volume: limits.volumeName)
        }
    }

    private static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int64.max : sum
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

/// One descriptor-relative walk, retaining only a bounded report.
private struct PreflightScan {
    let limits: FileEngine.DestinationLimits
    var report: PreflightReport
    var bytes: Int64 = 0

    mutating func visit(_ location: CopyLocation, relative: String) throws {
        try Task.checkCancellation()
        if limits.usesFATNames, !FileEngine.isStorableOnFAT(location.name) {
            report.add(path: relative, reason: .invalidName)
        }
        let info = try location.info()
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            let directory = try location.open(O_RDONLY | O_DIRECTORY, matching: info)
            for child in try CopyLocation.names(in: directory, path: location.path).sorted() {
                try visit(location.child(child, in: directory), relative: relative + "/" + child)
            }
        case S_IFREG:
            let size = Int64(info.st_size)
            if let limit = limits.maxFileSize, size > limit {
                report.add(path: relative, reason: .fileTooLarge(limit: limit))
            }
            let (sum, overflow) = bytes.addingReportingOverflow(max(0, size))
            bytes = overflow ? Int64.max : sum
        case S_IFLNK:
            switch limits.symbolicLinks {
            case .supported: break
            case .unsupported: report.add(path: relative, reason: .symbolicLinksUnsupported)
            case .unknown: report.add(path: relative, reason: .symbolicLinksUnknown)
            }
        default:
            break
        }
    }
}
