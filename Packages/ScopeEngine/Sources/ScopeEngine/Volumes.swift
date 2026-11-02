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
    /// must pass the path guard.
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
    /// Disk Arbitration's forced unmount. Only the chosen volume is unmounted;
    /// other volumes on the same disk stay mounted, and the disk itself is
    /// ejected only once nothing on it is mounted. Apps with files open on the
    /// volume can lose unsaved changes, so this counts as a write for the path
    /// guard, and internal disks and the startup disk are refused.
    public static func forceEject(_ url: URL, pathGuard: PathGuard) async throws {
        let volume = try pathGuard.checkWriteLocation(url)
        if let reason = forceEjectRefusal(volume) {
            throw CocoaError(
                .fileWriteNoPermission,
                userInfo: [NSLocalizedDescriptionKey: "Scope doesn't force eject this disk. \(reason)"])
        }
        guard let session = DASessionCreate(kCFAllocatorDefault),
            let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL)
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        DASessionSetDispatchQueue(session, DispatchQueue.global())
        defer { DASessionSetDispatchQueue(session, nil) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = Unmanaged.passRetained(ContinuationBox(continuation)).toOpaque()
            DADiskUnmount(
                disk, DADiskUnmountOptions(kDADiskUnmountOptionForce),
                { _, dissenter, context in ContinuationBox.finish(context, dissenter) }, box)
        }
        // Ejecting never unmounts anything: Disk Arbitration refuses while
        // another volume on the disk is still mounted, which leaves it in use.
        guard let whole = DADiskCopyWholeDisk(disk) else { return }
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = Unmanaged.passRetained(ContinuationBox(continuation)).toOpaque()
            DADiskEject(
                whole, DADiskEjectOptions(kDADiskEjectOptionDefault),
                { _, dissenter, context in ContinuationBox.finish(context, dissenter) }, box)
        }
    }

    /// Why Scope won't force eject a volume, or nil when it will. Disk images
    /// and external disks can be force ejected; the startup disk and other
    /// internal disks can't, since the apps and the system using them would
    /// lose what they haven't saved.
    public static func forceEjectRefusal(_ url: URL) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
            let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL)
        else {
            return "It isn't a disk that can be ejected."
        }
        if let startup = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: "/") as CFURL),
            let startupName = wholeDiskName(startup), wholeDiskName(disk) == startupName
        {
            return "It's the startup disk."
        }
        if diskImagePath(for: url, session: session) != nil { return nil }
        let description = DADiskCopyDescription(disk) as? [String: Any]
        guard description?[kDADiskDescriptionDeviceInternalKey as String] as? Bool == false else {
            return "It's an internal disk."
        }
        return nil
    }

    /// The BSD name of the whole disk a volume is on, such as "disk4". For
    /// APFS this is the container, which all of its volumes share.
    private static func wholeDiskName(_ disk: DADisk) -> String? {
        let whole = DADiskCopyWholeDisk(disk) ?? disk
        return DADiskGetBSDName(whole).map { String(cString: $0) }
    }

    /// Finds the image file behind a volume by walking up the I/O Registry from
    /// the volume's disk to the disk image device. For APFS this passes through
    /// the container to the image's physical disk. Current macOS records the
    /// image as "DiskImageURL"; older drivers used "image-path".
    static func diskImagePath(for url: URL, session: DASession) -> String? {
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

    /// Resumes the continuation a Disk Arbitration callback's context holds.
    static func finish(_ context: UnsafeMutableRawPointer?, _ dissenter: DADissenter?) {
        let box = Unmanaged<ContinuationBox>.fromOpaque(context!).takeRetainedValue()
        if let dissenter {
            box.continuation.resume(
                throwing: CocoaError(
                    .fileWriteUnknown,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Couldn't force eject (status \(DADissenterGetStatus(dissenter)))."
                    ]))
        } else {
            box.continuation.resume()
        }
    }
}
