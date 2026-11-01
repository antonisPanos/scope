import Foundation
import PandoraEngine

/// App-wide preferences, shared by every window and saved between launches.
/// Changes are announced with `didChange` so open windows follow along.
@MainActor
final class AppSettings {
    static let shared = AppSettings()
    static let didChange = Notification.Name("PandoraSettingsDidChange")
    static let iconSizeDidChange = Notification.Name("PandoraIconSizeDidChange")

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

    /// Icon size in the icon grid, in points.
    var iconSize: Double {
        get { defaults.object(forKey: "iconSize") as? Double ?? 64 }
        set {
            defaults.set(min(max(newValue, Self.iconSizes.lowerBound), Self.iconSizes.upperBound), forKey: "iconSize")
            // Its own notification: a slider drag mustn't re-sort every open folder.
            NotificationCenter.default.post(name: Self.iconSizeDidChange, object: self)
        }
    }

    static let iconSizes: ClosedRange<Double> = 16...256

    var showPreviewPane: Bool {
        get { defaults.object(forKey: "showPreviewPane") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showPreviewPane") }
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
    /// A grid of icons or thumbnails that re-flows to the window width.
    case icons
    /// Columns for date, size and kind, with folders that expand in place.
    case details
    /// One column per folder level, Finder style.
    case columns
    /// A large preview of the selection above a strip of thumbnails.
    case gallery
    /// Names only, one per row.
    case list

    var title: String {
        switch self {
        case .icons: "Icons"
        case .details: "Details"
        case .columns: "Columns"
        case .gallery: "Gallery"
        case .list: "List"
        }
    }

    var symbolName: String {
        switch self {
        case .icons: "square.grid.2x2"
        case .details: "list.bullet.indent"
        case .columns: "rectangle.split.3x1"
        case .gallery: "rectangle.bottomhalf.inset.filled"
        case .list: "list.bullet"
        }
    }

    /// Finder's shortcuts: Cmd+1 to Cmd+4; the plain list takes Cmd+5.
    var shortcut: String {
        switch self {
        case .icons: "1"
        case .details: "2"
        case .columns: "3"
        case .gallery: "4"
        case .list: "5"
        }
    }
}
