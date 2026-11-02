import Foundation

/// Bounded AppleDouble metadata, compatible with Finder/ditto. Decoding is
/// used by the archive reader (the sandboxed service in the app); the writer
/// receives only names and data, never an opaque blob to unpack on disk.
enum AppleDouble {
    static let limit = 64 * 1024 * 1024
    private static let resource = "com.apple.ResourceFork"
    private static let finder = "com.apple.FinderInfo"

    static func decode(_ data: Data) throws -> [String: Data] {
        guard data.count <= limit, data.count >= 26 else { throw invalid() }
        func number(_ offset: Int, _ length: Int = 4) throws -> Int {
            guard offset >= 0, length <= data.count, offset <= data.count - length else { throw invalid() }
            return data[data.startIndex + offset..<data.startIndex + offset + length].reduce(0) { ($0 << 8) | Int($1) }
        }
        func bytes(_ offset: Int, _ length: Int) throws -> Data {
            guard offset >= 0, length >= 0, length <= data.count, offset <= data.count - length else { throw invalid() }
            return data.subdata(in: data.startIndex + offset..<data.startIndex + offset + length)
        }
        guard try number(0) == 0x0005_1607, try number(4) == 0x0002_0000 else { throw invalid() }
        let count = try number(24, 2)
        guard count <= 1024, 26 + count * 12 <= data.count else { throw invalid() }
        var result: [String: Data] = [:]
        for index in 0..<count {
            let record = 26 + index * 12
            let kind = try number(record)
            let offset = try number(record + 4)
            let length = try number(record + 8)
            let value = try bytes(offset, length)
            if kind == 2, length > 0 { result[resource] = value }
            guard kind == 9 else { continue }
            guard length >= 32 else { throw invalid() }
            let info = value.prefix(32)
            if info.contains(where: { $0 != 0 }) { result[finder] = Data(info) }
            let header = offset + 34
            guard length >= 70, try number(header) == 0x4154_5452 else { continue }
            let total = try number(header + 8)
            let start = try number(header + 12)
            let dataLength = try number(header + 16)
            let attributes = try number(header + 34, 2)
            guard attributes <= 4096, start >= header + 36, total <= offset + length,
                start <= total, dataLength <= total - start
            else { throw invalid() }
            var position = header + 36
            for _ in 0..<attributes {
                let attrOffset = try number(position)
                let attrLength = try number(position + 4)
                let nameLength = try number(position + 10, 1)
                guard nameLength > 1, nameLength <= 128, position + 11 + nameLength <= start else { throw invalid() }
                let nameData = try bytes(position + 11, nameLength)
                guard nameData.last == 0, !nameData.dropLast().contains(0),
                    let name = String(data: nameData.dropLast(), encoding: .utf8),
                    attrOffset >= start, attrOffset <= total, attrLength <= total - attrOffset,
                    result[name] == nil
                else { throw invalid() }
                result[name] = try bytes(attrOffset, attrLength)
                position += (11 + nameLength + 3) & ~3
            }
        }
        return result
    }

    static func encode(_ attributes: [String: Data]) throws -> Data {
        let resourceData = attributes[resource] ?? Data()
        let finderData = attributes[finder] ?? Data(repeating: 0, count: 32)
        guard finderData.count == 32 else { throw invalid() }
        let names = attributes.keys.filter { $0 != resource && $0 != finder }.sorted()
        guard names.count <= 4096, names.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count < 128 }) else {
            throw invalid()
        }
        let start = 120 + names.reduce(0) { $0 + ((12 + $1.utf8.count + 3) & ~3) }
        var dataSize = 0
        for value in attributes.values {
            guard value.count <= limit - dataSize else { throw invalid() }
            dataSize += value.count
        }
        guard start <= limit - dataSize else { throw invalid() }
        let payload = names.reduce(0) { $0 + (attributes[$1]?.count ?? 0) }
        let resourceOffset = start + payload
        var data = Data(repeating: 0, count: resourceOffset + resourceData.count)
        func put(_ value: Int, at offset: Int, length: Int = 4) {
            for index in 0..<length {
                data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * (length - 1 - index)))
            }
        }
        put(0x0005_1607, at: 0)
        put(0x0002_0000, at: 4)
        data.replaceSubrange(8..<24, with: Data("Mac OS X        ".utf8))
        put(2, at: 24, length: 2)
        put(9, at: 26)
        put(50, at: 30)
        put(resourceOffset - 50, at: 34)
        put(2, at: 38)
        put(resourceOffset, at: 42)
        put(resourceData.count, at: 46)
        data.replaceSubrange(50..<82, with: finderData)
        put(0x4154_5452, at: 84)
        put(resourceOffset, at: 92)
        put(start, at: 96)
        put(payload, at: 100)
        put(names.count, at: 118, length: 2)
        var position = 120
        var offset = start
        for name in names {
            let value = attributes[name] ?? Data()
            let nameData = Data(name.utf8) + Data([0])
            put(offset, at: position)
            put(value.count, at: position + 4)
            put(nameData.count, at: position + 10, length: 1)
            data.replaceSubrange(position + 11..<position + 11 + nameData.count, with: nameData)
            data.replaceSubrange(offset..<offset + value.count, with: value)
            position += (11 + nameData.count + 3) & ~3
            offset += value.count
        }
        data.replaceSubrange(resourceOffset..<data.count, with: resourceData)
        return data
    }

    static func invalid() -> OperationError {
        .archive("The archive's macOS metadata is invalid or exceeds the supported 64 MB per-item limit.")
    }
}
