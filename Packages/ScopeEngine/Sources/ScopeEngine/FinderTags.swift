import Foundation

/// Finder stores tag names and their optional colour numbers in a binary plist.
/// Descriptor I/O changes the checked item itself, including symbolic links.
enum FinderTags {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"
    private static let colors = ["Gray": 1, "Green": 2, "Purple": 3, "Blue": 4, "Yellow": 5, "Red": 6, "Orange": 7]

    static func open(_ location: CopyLocation) throws -> CopyDescriptor {
        let info = try location.info()
        return try location.open(info.st_mode & S_IFMT == S_IFLNK ? O_SYMLINK : O_EVTONLY, matching: info)
    }

    static func read(_ descriptor: CopyDescriptor, path: String) throws -> [String] {
        let count = fgetxattr(descriptor.raw, attribute, nil, 0, 0, 0)
        if count < 0, errno == ENOATTR {
            // Older files can have a Finder label without a tag plist.
            let finder = try finderInfo(descriptor, path: path)
            let color = Int((finder[9] & 0x0e) >> 1)
            guard let name = colors.first(where: { $0.value == color })?.key else { return [] }
            return [encode(name)]
        }
        guard count >= 0 else { throw FileEngineError.posix("Read tags", path) }
        guard count <= 1024 * 1024 else { throw FileEngineError.tooLarge(path) }
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { fgetxattr(descriptor.raw, attribute, $0.baseAddress, count, 0, 0) }
        guard read >= 0 else { throw FileEngineError.posix("Read tags", path) }
        data.count = read
        guard let tags = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return tags
    }

    static func name(of stored: String) -> String {
        String(stored.prefix { $0 != "\n" })
    }

    static func encode(_ name: String) -> String {
        "\(name)\n\(colors[name] ?? 0)"
    }

    static func write(_ tags: [String], to descriptor: CopyDescriptor, path: String) throws {
        // Foundation also maintains Finder's legacy label bits. Preserve
        // every other FinderInfo byte, including custom-icon and hidden flags.
        var finder = try finderInfo(descriptor, path: path)
        let color =
            tags.reversed().compactMap { tag -> UInt8? in
                let parts = tag.split(separator: "\n", omittingEmptySubsequences: false)
                guard parts.count == 2, let value = UInt8(parts[1]), (1...7).contains(value) else { return nil }
                return value
            }.first ?? 0
        let flags = (finder[9] & ~UInt8(0x0e)) | (color << 1)
        let data = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
        let result = data.withUnsafeBytes { fsetxattr(descriptor.raw, attribute, $0.baseAddress, data.count, 0, 0) }
        guard result == 0 else { throw FileEngineError.posix("Set tags", path) }
        if flags != finder[9] {
            finder[9] = flags
            guard fsetxattr(descriptor.raw, "com.apple.FinderInfo", finder, finder.count, 0, 0) == 0 else {
                throw FileEngineError.posix("Set Finder label", path)
            }
        }
    }

    static func names(at checked: URL) throws -> [String] {
        let descriptor = try open(CopyLocation(checked: checked))
        return try read(descriptor, path: checked.path).map { name(of: $0) }
    }

    private static func finderInfo(_ descriptor: CopyDescriptor, path: String) throws -> [UInt8] {
        var finder = [UInt8](repeating: 0, count: 32)
        let count = fgetxattr(descriptor.raw, "com.apple.FinderInfo", &finder, finder.count, 0, 0)
        guard count == 32 || (count < 0 && errno == ENOATTR) else {
            throw FileEngineError.posix("Read Finder label", path)
        }
        return finder
    }
}
