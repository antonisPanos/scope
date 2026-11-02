import Foundation

enum ArchiveAttributes {
    // Archive-supplied security/compression state must not weaken quarantine,
    // confer access, or describe data that was extracted decompressed.
    private static let excluded: Set<String> = [
        "com.apple.quarantine", "com.apple.provenance", "com.apple.macl", "com.apple.rootless",
        "com.apple.decmpfs", "com.apple.system.Security", "com.apple.acl.text",
    ]

    static func validate(_ attributes: [String: Data]) throws {
        if attributes["com.apple.acl.text"] != nil || attributes["com.apple.system.Security"] != nil {
            throw OperationError.archive(
                "This archive contains access rules Scope cannot restore. Nothing was extracted.")
        }
        guard attributes.count <= 4096 else { throw AppleDouble.invalid() }
        var total = 0
        for (name, value) in attributes {
            guard !name.isEmpty, name.utf8.count < 128, !name.utf8.contains(0),
                value.count <= AppleDouble.limit - total
            else { throw AppleDouble.invalid() }
            total += value.count
        }
        if let finder = attributes["com.apple.FinderInfo"], finder.count != 32 { throw AppleDouble.invalid() }
    }

    static func read(_ descriptor: Int32) throws -> [String: Data] {
        let length = flistxattr(descriptor, nil, 0, 0)
        guard length >= 0 else { throw FileEngineError.posix("Read archive attributes", "open item") }
        guard length <= 1024 * 1024 else { throw AppleDouble.invalid() }
        var names = [CChar](repeating: 0, count: length)
        guard flistxattr(descriptor, &names, length, 0) == length else {
            throw FileEngineError.posix("Read archive attributes", "open item")
        }
        var attributes: [String: Data] = [:]
        var total = 0
        for bytes in names.split(separator: 0) {
            let name = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if excluded.contains(name) { continue }
            let count = fgetxattr(descriptor, name, nil, 0, 0, 0)
            guard count >= 0 else { throw FileEngineError.posix("Read archive attribute", name) }
            guard count <= AppleDouble.limit - total else { throw AppleDouble.invalid() }
            total += count
            var data = Data(count: count)
            let read = data.withUnsafeMutableBytes { fgetxattr(descriptor, name, $0.baseAddress, count, 0, 0) }
            guard read == count else { throw FileEngineError.posix("Read archive attribute", name) }
            attributes[name] = data
        }
        try validate(attributes)
        return attributes
    }

    static func apply(_ attributes: [String: Data], to descriptor: Int32) throws {
        try validate(attributes)
        for (name, value) in attributes where !excluded.contains(name) {
            try Task.checkCancellation()
            let result = value.withUnsafeBytes { fsetxattr(descriptor, name, $0.baseAddress, value.count, 0, 0) }
            guard result == 0 else { throw FileEngineError.posix("Restore archive attribute", name) }
        }
    }
}
