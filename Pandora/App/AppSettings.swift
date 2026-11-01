import Foundation
import PandoraEngine

/// App-wide preferences, shared by every window and saved between launches.
/// Changes are announced with `didChange` so open windows follow along.
@MainActor
final class AppSettings {
    static let shared = AppSettings()
    static let didChange = Notification.Name("PandoraSettingsDidChange")

    private let defaults = UserDefaults.standard

    var showHiddenFiles: Bool {
        get { defaults.bool(forKey: "showHiddenFiles") }
        set { defaults.set(newValue, forKey: "showHiddenFiles"); announce() }
    }

    /// The view mode and sort a new tab starts with: whatever was used last.
    var lastViewMode: ViewMode {
        get { defaults.string(forKey: "lastViewMode").flatMap(ViewMode.init(rawValue:)) ?? .details }
        set { defaults.set(newValue.rawValue, forKey: "lastViewMode") }
    }

    var lastSort: FileSort {
        get {
            guard let data = defaults.data(forKey: "lastSort"),
                  let sort = try? JSONDecoder().decode(FileSort.self, from: data) else { return FileSort() }
            return sort
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "lastSort") }
    }

    /// Folders the user added to the sidebar's Favorites, as paths.
    var favoritePaths: [String] {
        get { defaults.stringArray(forKey: "favoritePaths") ?? [] }
        set { defaults.set(newValue, forKey: "favoritePaths"); announce() }
    }

    private func announce() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

enum ViewMode: String, CaseIterable, Sendable {
    /// Names only, one per row.
    case list
    /// Columns for date, size and kind, with folders that expand in place.
    case details

    var title: String {
        switch self {
        case .list: "List"
        case .details: "Details"
        }
    }

    var symbolName: String {
        switch self {
        case .list: "list.bullet"
        case .details: "list.bullet.indent"
        }
    }
}
