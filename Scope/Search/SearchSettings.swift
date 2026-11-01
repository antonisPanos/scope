import Foundation
import Observation
import ScopeEngine

/// The search field and filter bar of one window, turned into a query.
@MainActor
@Observable
final class SearchSettings {
    enum Mode: String, CaseIterable, Identifiable {
        case contains, glob, regex, contents
        var id: String { rawValue }

        var title: String {
            switch self {
            case .contains: "Name contains"
            case .glob: "Name matches (*.pdf)"
            case .regex: "Regular expression"
            case .contents: "Contents (Spotlight)"
            }
        }
    }

    enum SizeFilter: String, CaseIterable, Identifiable {
        case any, under1MB, over1MB, over100MB, over1GB
        var id: String { rawValue }

        var title: String {
            switch self {
            case .any: "Any size"
            case .under1MB: "Under 1 MB"
            case .over1MB: "Over 1 MB"
            case .over100MB: "Over 100 MB"
            case .over1GB: "Over 1 GB"
            }
        }
    }

    enum DateFilter: String, CaseIterable, Identifiable {
        case any, today, week, month, year, olderThanYear
        var id: String { rawValue }

        var title: String {
            switch self {
            case .any: "Any date"
            case .today: "Today"
            case .week: "Last 7 days"
            case .month: "Last 30 days"
            case .year: "Last 12 months"
            case .olderThanYear: "Older than a year"
            }
        }
    }

    var text = ""
    var mode: Mode = .contains
    var includeHidden = false
    var includeSubfolders = true
    var includePackages = false
    var kinds: Set<SearchQuery.Kind> = []
    var size: SizeFilter = .any
    var modified: DateFilter = .any
    var tag: String?

    var query: SearchQuery {
        var query = SearchQuery(
            text: text, mode: mode == .glob ? .glob : mode == .regex ? .regex : .contains,
            includeHidden: includeHidden, includeSubfolders: includeSubfolders,
            includePackages: includePackages, kinds: kinds, tag: tag)
        query.searchContents = mode == .contents
        switch size {
        case .any: break
        case .under1MB: query.maximumSize = 1_000_000
        case .over1MB: query.minimumSize = 1_000_000
        case .over100MB: query.minimumSize = 100_000_000
        case .over1GB: query.minimumSize = 1_000_000_000
        }
        let day: TimeInterval = 24 * 3600
        switch modified {
        case .any: break
        case .today: query.modifiedAfter = Calendar.current.startOfDay(for: Date())
        case .week: query.modifiedAfter = Date(timeIntervalSinceNow: -7 * day)
        case .month: query.modifiedAfter = Date(timeIntervalSinceNow: -30 * day)
        case .year: query.modifiedAfter = Date(timeIntervalSinceNow: -365 * day)
        case .olderThanYear: query.modifiedBefore = Date(timeIntervalSinceNow: -365 * day)
        }
        return query
    }

    func reset() {
        text = ""
        mode = .contains
        includeHidden = false
        includeSubfolders = true
        includePackages = false
        kinds = []
        size = .any
        modified = .any
        tag = nil
    }
}
