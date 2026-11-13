import DiskArbitration
import Foundation
import os

/// The two mounted APFS volumes used by an explicit Scope Dev stress run.
/// Discovery is engine-owned so the app never constructs a permissive guard
/// from an unchecked path or an environment variable alone.
public struct StressImageAccess: Sendable {
    private static let logger = Logger(subsystem: "com.antonispanos.scope", category: "StressLaunch")
    public let source: URL
    public let target: URL
    public let pathGuard: PathGuard

    public static func open(image: URL, sourceUUID: UUID, targetUUID: UUID) throws -> StressImageAccess {
        guard image.isFileURL, image.path.hasPrefix("/"), sourceUUID != targetUUID,
            let expectedImage = canonicalPath(image.path),
            let session = DASessionCreate(kCFAllocatorDefault)
        else { throw StressImageError.invalidConfiguration }

        let mounted =
            (FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeLocalizedNameKey], options: []) ?? []).filter { volume in
                guard let imagePath = Volumes.diskImagePath(for: volume, session: session) else { return false }
                return canonicalPath(imagePath) == expectedImage
            }
        let candidates = mounted.map { volume in
            let name = (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            let uuid = volumeUUID(volume, session: session)
            let writable = isWritable(volume)
            logger.notice(
                "run=\(ProcessInfo.processInfo.environment["SCOPE_STRESS_RUN_ID"] ?? "unknown", privacy: .public) candidate=\(name ?? "unknown", privacy: .public) uuid=\(uuid?.uuidString ?? "none", privacy: .public) writable=\(writable)"
            )
            return (url: volume, name: name, uuid: uuid, writable: writable)
        }
        func find(_ uuid: UUID, name: String) -> URL? {
            candidates.first { $0.name == name && $0.uuid == uuid && $0.writable }?.url
        }
        guard let source = find(sourceUUID, name: "ScopeStressSource"),
            let target = find(targetUUID, name: "ScopeStressTarget")
        else { throw StressImageError.volumesNotVerified }

        let guardPolicy = try PathGuard.restrictedToMountedVolumes([source, target])
        return StressImageAccess(source: source, target: target, pathGuard: guardPolicy)
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func volumeUUID(_ url: URL, session: DASession) -> UUID? {
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
            let description = DADiskCopyDescription(disk) as? [String: Any],
            let value = description[kDADiskDescriptionVolumeUUIDKey as String]
        else { return nil }
        if let uuid = value as? UUID { return uuid }
        guard CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
        return UUID(uuidString: CFUUIDCreateString(kCFAllocatorDefault, (value as! CFUUID)) as String)
    }

    private static func isWritable(_ url: URL) -> Bool {
        var fileSystem = statfs()
        guard statfs(url.path, &fileSystem) == 0, fileSystem.f_flags & UInt32(MNT_RDONLY) == 0 else {
            return false
        }
        let type = withUnsafeBytes(of: fileSystem.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return type == "apfs"
    }
}

public enum StressImageError: Error, LocalizedError {
    case invalidConfiguration
    case volumesNotVerified

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The stress image path or volume IDs are invalid."
        case .volumesNotVerified:
            "Both writable ScopeStress volumes must be mounted from the specified image with matching UUIDs."
        }
    }
}
