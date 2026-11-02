import Foundation

/// A tag is applied to the selection only when every item has it.
enum TagSelection {
    static func commonTags(
        in urls: [URL], readTags: @Sendable (URL) async throws -> [String]
    ) async throws -> Set<String> {
        var common: Set<String>?
        for url in urls {
            try Task.checkCancellation()
            let tags = Set((try? await readTags(url)) ?? [])
            common = common.map { $0.intersection(tags) } ?? tags
            // Later items can only shrink the intersection.
            if common?.isEmpty == true { break }
        }
        try Task.checkCancellation()
        return common ?? []
    }
}
