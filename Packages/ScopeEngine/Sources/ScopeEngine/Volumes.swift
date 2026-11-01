import DiskArbitration
import Foundation
import IOKit

/// A mounted volume, as the sidebar shows it.
public struct VolumeInfo: Sendable, Hashable, Identifiable {
    public var id: URL { url }

    public let url: URL
    public let name: String
    public let isInternal: Bool
    public let isEjectable: Bool
    public let isRootVolume: Bool
    /// The disk image file this volume was mounted from, when it is a disk image.
    public let imagePath: String?
    public let totalCapacity: Int64?
    public let availableCapacity: Int64?

    public var isDiskImage: Bool { imagePath != nil }
}

public enum Volumes {
    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
        .volumeIsRootFileSystemKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsBrowsableKey,
    ]

    /// Mounted volumes that Finder would show, the startup disk first.
    public static func mounted() -> [VolumeInfo] {
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys,
                options: [.skipHiddenVolumes]) ?? []
        let session = DASessionCreate(kCFAllocatorDefault)
        let volumes = urls.compactMap { url -> VolumeInfo? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.volumeIsBrowsable ?? true
            else { return nil }
            let imagePath = session.flatMap { diskImagePath(for: url, session: $0) }
            let isRoot = values.volumeIsRootFileSystem ?? false
            return VolumeInfo(
                url: url,
                name: values.volumeLocalizedName ?? url.lastPathComponent,
                isInternal: values.volumeIsInternal ?? false,
                isEjectable: !isRoot
                    && (imagePath != nil || values.volumeIsEjectable == true
                        || values.volumeIsRemovable == true || values.volumeIsInternal == false),
                isRootVolume: isRoot,
                imagePath: imagePath,
                totalCapacity: values.volumeTotalCapacity.map(Int64.init),
                availableCapacity: values.volumeAvailableCapacityForImportantUsage)
        }
        return volumes.sorted { a, b in
            if a.isRootVolume != b.isRootVolume { return a.isRootVolume }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Ejects a volume and, for a disk image, detaches the image. The volume
    /// must pass the path guard, so development builds can only eject the
    /// test disks.
    public static func eject(_ url: URL, pathGuard: PathGuard) async throws {
        let volume = try pathGuard.checkLocation(url)
        try await FileManager.default.unmountVolume(at: volume, options: [.allPartitionsAndEjectDisk, .withoutUI])
    }

    /// The app keeping a volume busy, from an eject error, when macOS says which.
    public static func blockingApp(from error: Error) -> String? {
        let info = (error as NSError).userInfo
        guard let pid = info[NSFileManagerUnmountDissentingProcessIdentifierErrorKey] as? pid_t else { return nil }
        var name = [UInt8](repeating: 0, count: 1024)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return "process \(pid)" }
        return String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Ejects even when an app still has files open on the volume, through
    /// Disk Arbitration's forced unmount. The guard applies as for `eject`.
    public static func forceEject(_ url: URL, pathGuard: PathGuard) async throws {
        let volume = try pathGuard.checkLocation(url)
        guard let session = DASessionCreate(kCFAllocatorDefault),
            let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL)
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        DASessionSetDispatchQueue(session, DispatchQueue.global())
        let whole = DADiskCopyWholeDisk(disk) ?? disk
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = Unmanaged.passRetained(ContinuationBox(continuation)).toOpaque()
            DADiskUnmount(
                whole, DADiskUnmountOptions(kDADiskUnmountOptionForce | kDADiskUnmountOptionWhole),
                { _, dissenter, context in
                    let box = Unmanaged<ContinuationBox>.fromOpaque(context!).takeRetainedValue()
                    if let dissenter {
                        box.continuation.resume(
                            throwing: CocoaError(
                                .fileWriteUnknown,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "Couldn't force eject (status \(DADissenterGetStatus(dissenter)))."
                                ]))
                    } else {
                        box.continuation.resume()
                    }
                }, box)
        }
        DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault), nil, nil)
        DASessionSetDispatchQueue(session, nil)
    }

    /// Finds the image file behind a volume by walking up the I/O Registry from
    /// the volume's disk to the disk image device. For APFS this passes through
    /// the container to the image's physical disk. Current macOS records the
    /// image as "DiskImageURL"; older drivers used "image-path".
    private static func diskImagePath(for url: URL, session: DASession) -> String? {
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else { return nil }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)

        if let value = IORegistryEntrySearchCFProperty(
            media, kIOServicePlane, "DiskImageURL" as CFString,
            kCFAllocatorDefault, options) as? String,
            let imageURL = URL(string: value), imageURL.isFileURL
        {
            return imageURL.path
        }
        guard
            let value = IORegistryEntrySearchCFProperty(
                media, kIOServicePlane, "image-path" as CFString,
                kCFAllocatorDefault, options)
        else { return nil }
        if let data = value as? Data {
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        }
        return value as? String
    }
}

private final class ContinuationBox: @unchecked Sendable {
    let continuation: CheckedContinuation<Void, Error>
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
}
