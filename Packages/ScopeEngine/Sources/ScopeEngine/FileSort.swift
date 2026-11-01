import Foundation

/// How a listing is ordered. Names compare the way Finder does: numbers by
/// value ("file 2" before "file 10"), ignoring case.
public struct FileSort: Sendable, Hashable, Codable {
    public enum Key: String, Sendable, Hashable, Codable, CaseIterable {
        case name, modified, created, added, size, kind
    }

    public var key: Key
    public var ascending: Bool

    public init(key: Key = .name, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    public func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted(by: areInIncreasingOrder)
    }

    public func areInIncreasingOrder(_ a: FileItem, _ b: FileItem) -> Bool {
        let order = compare(a, b)
        if order == .orderedSame {
            // Ties always fall back to the name, ascending, so the order is stable.
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return ascending ? order == .orderedAscending : order == .orderedDescending
    }

    private func compare(_ a: FileItem, _ b: FileItem) -> ComparisonResult {
        switch key {
        case .name: a.name.localizedStandardCompare(b.name)
        case .modified: Self.compare(a.modified, b.modified)
        case .created: Self.compare(a.created, b.created)
        case .added: Self.compare(a.added, b.added)
        case .size: Self.compare(a.size, b.size)
        case .kind: a.kind.localizedStandardCompare(b.kind)
        }
    }

    /// Missing values (folders have no size) sort before present ones.
    private static func compare<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): .orderedSame
        case (nil, _): .orderedAscending
        case (_, nil): .orderedDescending
        case let (x?, y?): x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        }
    }
}
