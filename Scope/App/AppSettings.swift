import Foundation
import ScopeEngine

/// App-wide preferences, shared by every window and saved between launches.
/// Changes are announced with `didChange` so open windows follow along.
@MainActor
final class AppSettings {
    static let shared = AppSettings()
    static let didChange = Notification.Name("ScopeSettingsDidChange")
    /// Refresh controls in open windows without changing their display snapshots.
    static let viewPreferencesDidChange = Notification.Name("ScopeViewPreferencesDidChange")

    private let defaults: UserDefaults
    private var folderPreferences: [String: FolderPreferences] = [:]
    static let folderPreferenceLimit = 2_000
    private static let folderPreferencesKey = "folderViewPreferences.v1"

    enum PreferenceScope: String, CaseIterable {
        case global, perFolder
        var title: String { self == .global ? "Global" : "Per folder" }
    }

    struct FolderPreferences {
        var viewMode: ViewMode?
        var iconSize: Double?
        var changed: Double = 0
        var isEmpty: Bool { viewMode == nil && iconSize == nil }
    }

    /// `defaults` is the app's own; tests pass a throwaway suite, so they
    /// never change the settings Scope Dev runs with.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.dictionary(forKey: Self.folderPreferencesKey) {
            for (key, value) in saved {
                guard let record = value as? [String: Any] else { continue }
                let size = record["iconSize"] as? Double
                let preference = FolderPreferences(
                    viewMode: (record["viewMode"] as? String).flatMap(ViewMode.init(rawValue:)),
                    iconSize: size.flatMap { $0.isFinite && Self.iconSizes.contains($0) ? $0 : nil },
                    changed: (record["changed"] as? Double).flatMap { $0.isFinite ? $0 : nil } ?? 0)
                if !preference.isEmpty { folderPreferences[key] = preference }
            }
            trimFolderPreferences()
        }
    }

    var showHiddenFiles: Bool {
        get { defaults.bool(forKey: "showHiddenFiles") }
        set {
            defaults.set(newValue, forKey: "showHiddenFiles")
            announce()
        }
    }

    /// Keep the old keys so existing global preferences become the defaults.
    var defaultViewMode: ViewMode {
        get { defaults.string(forKey: "lastViewMode").flatMap(ViewMode.init(rawValue:)) ?? .details }
        set {
            defaults.set(newValue.rawValue, forKey: "lastViewMode")
            announceViewPreferences()
        }
    }

    var lastSort: FileSort {
        get {
            guard let data = defaults.data(forKey: "lastSort"),
                let sort = try? JSONDecoder().decode(FileSort.self, from: data)
            else { return FileSort() }
            return sort
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "lastSort") }
    }

    /// Icon size in the icon grid, in points.
    var defaultIconSize: Double {
        get { Self.validIconSize(defaults.object(forKey: "iconSize") as? Double ?? Self.factoryIconSize) }
        set {
            defaults.set(Self.validIconSize(newValue), forKey: "iconSize")
            announceViewPreferences()
        }
    }

    static let iconSizes: ClosedRange<Double> = 16...256
    static let factoryIconSize: Double = 64

    static func validIconSize(_ value: Double) -> Double {
        value.isFinite ? min(max(value, iconSizes.lowerBound), iconSizes.upperBound) : factoryIconSize
    }

    var viewTypeScope: PreferenceScope {
        get { defaults.string(forKey: "viewTypeScope").flatMap(PreferenceScope.init(rawValue:)) ?? .global }
        set {
            defaults.set(newValue.rawValue, forKey: "viewTypeScope")
            announceViewPreferences()
        }
    }

    var iconSizeScope: PreferenceScope {
        get { defaults.string(forKey: "iconSizeScope").flatMap(PreferenceScope.init(rawValue:)) ?? .global }
        set {
            defaults.set(newValue.rawValue, forKey: "iconSizeScope")
            announceViewPreferences()
        }
    }

    func preferences(for identity: FolderPreferenceIdentity) -> FolderPreferences {
        folderPreferences[identity.storageKey] ?? FolderPreferences()
    }

    func setViewMode(_ mode: ViewMode?, for identity: FolderPreferenceIdentity) {
        var record = preferences(for: identity)
        record.viewMode = mode
        save(record, for: identity)
    }

    func setIconSize(_ size: Double?, for identity: FolderPreferenceIdentity) {
        var record = preferences(for: identity)
        record.iconSize = size.map(Self.validIconSize)
        save(record, for: identity)
    }

    func resetSavedFolderViewTypes() {
        for key in Array(folderPreferences.keys) {
            folderPreferences[key]?.viewMode = nil
        }
        persistFolderPreferences()
    }

    func resetSavedFolderIconSizes() {
        for key in Array(folderPreferences.keys) {
            folderPreferences[key]?.iconSize = nil
        }
        persistFolderPreferences()
    }

    private func save(_ preference: FolderPreferences, for identity: FolderPreferenceIdentity) {
        var record = preference
        record.changed = Date.timeIntervalSinceReferenceDate
        folderPreferences[identity.storageKey] = record
        persistFolderPreferences()
    }

    private func trimFolderPreferences() {
        folderPreferences = folderPreferences.filter { !$0.value.isEmpty }
        let excess = folderPreferences.count - Self.folderPreferenceLimit
        guard excess > 0 else { return }
        let oldest = folderPreferences.sorted {
            $0.value.changed == $1.value.changed ? $0.key < $1.key : $0.value.changed < $1.value.changed
        }
        for entry in oldest.prefix(excess) { folderPreferences[entry.key] = nil }
    }

    private func persistFolderPreferences() {
        trimFolderPreferences()
        let saved = folderPreferences.mapValues { record -> [String: Any] in
            var value: [String: Any] = ["changed": record.changed]
            if let mode = record.viewMode { value["viewMode"] = mode.rawValue }
            if let size = record.iconSize { value["iconSize"] = size }
            return value
        }
        defaults.set(saved, forKey: Self.folderPreferencesKey)
        announceViewPreferences()
    }

    private func announceViewPreferences() {
        NotificationCenter.default.post(name: Self.viewPreferencesDidChange, object: self)
    }

    var showPreviewPane: Bool {
        get { defaults.object(forKey: "showPreviewPane") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showPreviewPane") }
    }

    /// Post finished, failed and waiting jobs to Notification Center.
    var systemNotifications: Bool {
        get { defaults.object(forKey: "systemNotifications") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "systemNotifications") }
    }

    // MARK: - Alternative shortcuts (Settings > Shortcuts)

    enum DeleteKey: String, CaseIterable, Identifiable {
        /// Finder: Delete alone does nothing in a file list.
        case nothing
        case goBack
        case moveToTrash
        var id: String { rawValue }

        var title: String {
            switch self {
            case .nothing: "Does nothing (Finder)"
            case .goBack: "Goes back (Windows, Dolphin)"
            case .moveToTrash: "Moves to the Trash"
            }
        }
    }

    /// Return opens the selection instead of renaming it (then F2 renames).
    var returnOpens: Bool {
        get { defaults.bool(forKey: "returnOpens") }
        set { defaults.set(newValue, forKey: "returnOpens") }
    }

    var f2Renames: Bool {
        get { defaults.object(forKey: "f2Renames") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "f2Renames") }
    }

    var f5Reloads: Bool {
        get { defaults.object(forKey: "f5Reloads") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "f5Reloads") }
    }

    /// Cmd+X cuts files, and the next paste moves them (Finder: Cmd+C, then Option+Cmd+V).
    var commandXCuts: Bool {
        get { defaults.object(forKey: "commandXCuts") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "commandXCuts") }
    }

    /// Option+Left and Option+Right go back and forward, like a browser.
    var optionArrowsNavigate: Bool {
        get { defaults.bool(forKey: "optionArrowsNavigate") }
        set { defaults.set(newValue, forKey: "optionArrowsNavigate") }
    }

    var deleteKey: DeleteKey {
        get { defaults.string(forKey: "deleteKey").flatMap(DeleteKey.init(rawValue:)) ?? .nothing }
        set { defaults.set(newValue.rawValue, forKey: "deleteKey") }
    }

    /// Folders the user added to the sidebar's Favorites, as paths.
    var favoritePaths: [String] {
        get { defaults.stringArray(forKey: "favoritePaths") ?? [] }
        set {
            defaults.set(newValue, forKey: "favoritePaths")
            announce()
        }
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
    /// Compact names that fill columns from top to bottom and scroll horizontally.
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
        case .list: "rectangle.split.3x1.fill"
        }
    }

    /// Finder's shortcuts: Cmd+1 to Cmd+4; the compact list takes Cmd+5.
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
