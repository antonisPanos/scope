import Darwin
import Foundation

/// A directory's identity, independent of its name and mount point. The birth
/// time prevents a recycled object ID from inheriting an old folder's settings.
public struct FolderPreferenceIdentity: Hashable, Sendable {
    public let volumeUUID: UUID
    public let objectID: UInt64
    public let birthSeconds: Int64
    public let birthNanoseconds: Int64

    public init(volumeUUID: UUID, objectID: UInt64, birthSeconds: Int64, birthNanoseconds: Int64) {
        self.volumeUUID = volumeUUID
        self.objectID = objectID
        self.birthSeconds = birthSeconds
        self.birthNanoseconds = birthNanoseconds
    }

    public var storageKey: String {
        "\(volumeUUID.uuidString):\(objectID):\(birthSeconds):\(birthNanoseconds)"
    }
}

extension FileEngine {
    /// Returns nil rather than saving a path or a transient device/inode pair
    /// when a volume cannot promise persistent object IDs. This reads metadata
    /// only; it never allocates document IDs or mounts an unavailable volume.
    public func folderPreferenceIdentity(at url: URL) async -> FolderPreferenceIdentity? {
        await onIOThreads {
            do {
                try Task.checkCancellation()
                readValidationHook?()
                let checked = try pathGuard.checkTarget(url)
                let descriptor = try CopyDescriptor(
                    open(checked.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC), path: checked.path)
                let info = try descriptor.info()
                let values = try checked.resourceValues(forKeys: [
                    .volumeUUIDStringKey, .volumeSupportsPersistentIDsKey,
                ])
                guard values.volumeSupportsPersistentIDs == true,
                    let uuid = values.volumeUUIDString.flatMap(UUID.init(uuidString:))
                else { return nil }

                // ATTR_CMN_FILEID supports 64-bit object IDs (unlike the legacy
                // OBJPERMANENTID). Only persist it on a volume with the above
                // persistent-object-ID capability, never on an arbitrary FS.
                var attributes = attrlist()
                attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                attributes.commonattr = attrgroup_t(ATTR_CMN_FILEID)
                var bytes = [UInt8](repeating: 0, count: 12)
                let objectID: UInt64? = bytes.withUnsafeMutableBytes { buffer in
                    guard fgetattrlist(descriptor.raw, &attributes, buffer.baseAddress, buffer.count, 0) == 0,
                        buffer.loadUnaligned(as: UInt32.self) == 12
                    else { return nil }
                    return buffer.loadUnaligned(fromByteOffset: 4, as: UInt64.self)
                }
                // Do not combine a pinned directory ID with volume metadata
                // from a replacement at the path while this read was in flight.
                guard let objectID, objectID != 0,
                    let current = Self.statInfo(checked.path),
                    current.st_dev == info.st_dev, current.st_ino == info.st_ino,
                    !Task.isCancelled
                else { return nil }
                return FolderPreferenceIdentity(
                    volumeUUID: uuid, objectID: objectID,
                    birthSeconds: Int64(info.st_birthtimespec.tv_sec),
                    birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
            } catch {
                return nil
            }
        }
    }
}
