import Foundation

/// Fresh Launch Services quarantine bytes for items Scope makes from a
/// quarantined source (#159). Launch Services only takes a path, so it never
/// gets one in a user folder: it marks a private helper file in a new 0700
/// folder in Scope's own temporary folder, addressed by volume and file ID
/// (`/.vol/<device>/<inode>`) so no folder or name on the way can be swapped.
/// The bytes are read back through the helper's descriptor and then set on
/// each intended item through its own descriptor.
enum QuarantineStamp {
    static let attributeName = "com.apple.quarantine"

    /// The bytes Launch Services writes for `properties`. `beforeMarking`
    /// runs between creating the helper and marking it, with the helper's
    /// path; tests use it to swap the helper's name.
    static func bytes(for properties: [String: Any], beforeMarking: ((String) -> Void)? = nil) throws -> Data {
        let temporary = NSTemporaryDirectory()
        let parent = try CopyDescriptor(open(temporary, O_RDONLY | O_DIRECTORY | O_CLOEXEC), path: temporary)
        let folderName = "scope-quarantine-" + UUID().uuidString
        let folderPath = (temporary as NSString).appendingPathComponent(folderName)
        guard mkdirat(parent.raw, folderName, 0o700) == 0 else {
            throw FileEngineError.posix("Create folder", folderPath)
        }
        defer { _ = unlinkat(parent.raw, folderName, AT_REMOVEDIR) }
        let folder = try CopyDescriptor(
            openat(parent.raw, folderName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), path: folderPath)
        let helperName = "stamp"
        let helperPath = folderPath + "/" + helperName
        let helper = try CopyDescriptor(
            openat(folder.raw, helperName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600),
            path: helperPath)
        // Removes only the name, never what a swapped-in link points to.
        defer { _ = unlinkat(folder.raw, helperName, 0) }
        let identity = try helper.info()
        beforeMarking?(helperPath)

        var values = URLResourceValues()
        // The public Launch Services property, rather than copying the
        // source's raw flags, which could carry approval to the new items.
        values.quarantineProperties = properties
        var byID = URL(fileURLWithPath: "/.vol/\(UInt32(bitPattern: identity.st_dev))/\(identity.st_ino)")
        if (try? byID.setResourceValues(values)) != nil, let data = try read(helper) { return data }
        // A volume without file-ID paths: the helper's own name, which must
        // still be the helper. Either way only the helper is ever addressed.
        var value = stat()
        guard fstatat(folder.raw, helperName, &value, AT_SYMLINK_NOFOLLOW) == 0, CopyLocation.same(value, identity)
        else { throw FileEngineError.posix("Set quarantine", helperPath, EBUSY) }
        var byName = URL(fileURLWithPath: helperPath)
        try byName.setResourceValues(values)
        guard let data = try read(helper) else { throw FileEngineError.posix("Set quarantine", helperPath, EBUSY) }
        return data
    }

    /// Sets `data` as the quarantine of the item open as `descriptor`.
    static func apply(_ data: Data, to descriptor: Int32, path: String) throws {
        let result = data.withUnsafeBytes { fsetxattr(descriptor, attributeName, $0.baseAddress, data.count, 0, 0) }
        guard result == 0 else { throw FileEngineError.posix("Set quarantine", path) }
    }

    private static func read(_ descriptor: CopyDescriptor) throws -> Data? {
        let length = fgetxattr(descriptor.raw, attributeName, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes {
            fgetxattr(descriptor.raw, attributeName, $0.baseAddress, length, 0, 0)
        }
        guard read == length else { throw FileEngineError.posix("Read quarantine", "helper") }
        return data
    }
}
