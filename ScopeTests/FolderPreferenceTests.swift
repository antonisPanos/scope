import AppKit
import ScopeEngine
import SwiftUI
import Testing

@testable import Scope

/// Read-only app fixtures. Identities are values supplied by a test, not disk
/// probes; only the existing throwaway UserDefaults suite persists anything.
@MainActor
private final class FolderPreferenceFixture {
    let suite = "ScopeFolderPreferencesTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: AppSettings
    let root = TestPaths.packages
    let first = FolderPreferenceIdentity(volumeUUID: UUID(), objectID: 1, birthSeconds: 1, birthNanoseconds: 0)
    let second = FolderPreferenceIdentity(volumeUUID: UUID(), objectID: 2, birthSeconds: 2, birthNanoseconds: 0)
    private var models: [BrowserModel] = []

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults)
    }

    func model(
        at location: Location? = nil,
        resolver: (@MainActor (URL) async -> FolderPreferenceIdentity?)? = nil
    ) -> BrowserModel {
        let root = root
        let first = first
        let second = second
        let model = BrowserModel(
            engine: FileEngine(pathGuard: .readOnly), location: location ?? .folder(root), settings: settings,
            identityResolver: resolver ?? { $0 == root ? first : second })
        models.append(model)
        return model
    }

    func close() {
        models.forEach { $0.close() }
        defaults.removePersistentDomain(forName: suite)
    }

    func ready(_ model: BrowserModel) async throws {
        for _ in 0..<300 {
            if model.viewPreferencesReady { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.viewPreferencesReady)
    }
}

@MainActor
struct FolderPreferenceSettingsTests {
    @Test func migrationAndInvalidFields() throws {
        let fixture = try FolderPreferenceFixture()
        defer { fixture.close() }
        fixture.defaults.set("gallery", forKey: "lastViewMode")
        fixture.defaults.set(96.0, forKey: "iconSize")
        fixture.defaults.set(
            [
                fixture.first.storageKey: ["viewMode": "not-a-mode", "iconSize": 128.0, "changed": 4.0],
                fixture.second.storageKey: ["viewMode": "icons", "iconSize": -1.0],
            ], forKey: "folderViewPreferences.v1")
        let settings = AppSettings(defaults: fixture.defaults)
        #expect(settings.defaultViewMode == .gallery)
        #expect(settings.defaultIconSize == 96)
        #expect(settings.viewTypeScope == .global && settings.iconSizeScope == .global)
        #expect(settings.preferences(for: fixture.first).viewMode == nil)
        #expect(settings.preferences(for: fixture.first).iconSize == 128)
        #expect(settings.preferences(for: fixture.second).viewMode == .icons)
        #expect(settings.preferences(for: fixture.second).iconSize == nil)
        settings.defaultIconSize = .nan
        #expect(settings.defaultIconSize == 64)
        settings.defaultIconSize = 1000
        #expect(settings.defaultIconSize == 256)
    }

    @Test func independentFieldsAndBulkResetsSurviveRecreation() throws {
        let fixture = try FolderPreferenceFixture()
        defer { fixture.close() }
        let settings = fixture.settings
        settings.viewTypeScope = .perFolder
        settings.iconSizeScope = .perFolder
        settings.setViewMode(.columns, for: fixture.first)
        settings.setIconSize(128, for: fixture.first)
        // A default-valued override is still explicit.
        settings.setViewMode(settings.defaultViewMode, for: fixture.second)
        settings.setIconSize(settings.defaultIconSize, for: fixture.second)
        settings.viewTypeScope = .global
        settings.iconSizeScope = .global
        let restored = AppSettings(defaults: fixture.defaults)
        #expect(restored.preferences(for: fixture.first).viewMode == .columns)
        #expect(restored.preferences(for: fixture.first).iconSize == 128)
        #expect(restored.preferences(for: fixture.second).viewMode == .details)
        restored.resetSavedFolderViewTypes()
        #expect(restored.preferences(for: fixture.first).viewMode == nil)
        #expect(restored.preferences(for: fixture.first).iconSize == 128)
        restored.resetSavedFolderIconSizes()
        #expect(restored.preferences(for: fixture.first).isEmpty)
        #expect(restored.preferences(for: fixture.second).isEmpty)
        #expect(restored.defaultViewMode == .details && restored.defaultIconSize == 64)
        #expect(fixture.defaults.dictionary(forKey: "folderViewPreferences.v1")?.isEmpty == true)
    }

    @Test func readsDoNotRefreshTheEvictionOrder() throws {
        let fixture = try FolderPreferenceFixture()
        defer { fixture.close() }
        var saved: [String: Any] = [:]
        for index in 0..<AppSettings.folderPreferenceLimit {
            saved["entry-\(index)"] = ["viewMode": "icons", "changed": Double(index)]
        }
        saved[fixture.first.storageKey] = ["viewMode": "columns", "changed": -1.0]
        fixture.defaults.set(saved, forKey: "folderViewPreferences.v1")
        let settings = AppSettings(defaults: fixture.defaults)
        #expect(settings.preferences(for: fixture.first).isEmpty)
        // Loading trims the cache, but reads must not rewrite the saved data.
        #expect(fixture.defaults.dictionary(forKey: "folderViewPreferences.v1")?.count == saved.count)
        settings.setIconSize(96, for: fixture.second)
        let written = try #require(fixture.defaults.dictionary(forKey: "folderViewPreferences.v1"))
        #expect(written.count == AppSettings.folderPreferenceLimit)
        #expect(written["entry-0"] == nil)
        #expect(settings.preferences(for: fixture.second).iconSize == 96)
    }
}

@MainActor
struct FolderPreferenceNavigationTests {
    @Test(arguments: AppSettings.PreferenceScope.allCases, AppSettings.PreferenceScope.allCases)
    func scopesAreIndependent(
        viewScope: AppSettings.PreferenceScope, sizeScope: AppSettings.PreferenceScope
    ) async throws {
        let fixture = try FolderPreferenceFixture()
        defer { fixture.close() }
        let settings = fixture.settings
        settings.viewTypeScope = viewScope
        settings.iconSizeScope = sizeScope
        settings.setViewMode(.gallery, for: fixture.first)
        settings.setIconSize(128, for: fixture.first)
        let savedBefore = fixture.defaults.persistentDomain(forName: fixture.suite) as NSDictionary?
        let model = fixture.model()
        try await fixture.ready(model)
        #expect(model.viewMode == (viewScope == .perFolder ? .gallery : .details))
        #expect(model.iconSize == (sizeScope == .perFolder ? 128 : 64))
        #expect(fixture.defaults.persistentDomain(forName: fixture.suite) as NSDictionary? == savedBefore)
        model.setViewMode(.icons)
        model.setIconSize(96)
        #expect(settings.defaultViewMode == (viewScope == .global ? .icons : .details))
        #expect(settings.defaultIconSize == (sizeScope == .global ? 96 : 64))
        #expect(settings.preferences(for: fixture.first).viewMode == (viewScope == .perFolder ? .icons : .gallery))
        #expect(settings.preferences(for: fixture.first).iconSize == (sizeScope == .perFolder ? 96 : 128))
    }

    @Test func historyReopeningAndNewTabsResolveWithoutSaving() async throws {
        let fixture = try FolderPreferenceFixture()
        defer { fixture.close() }
        fixture.settings.viewTypeScope = .perFolder
        fixture.settings.iconSizeScope = .perFolder
        fixture.settings.setViewMode(.icons, for: fixture.first)
        fixture.settings.setIconSize(128, for: fixture.first)
        let model = fixture.model()
        try await fixture.ready(model)
        #expect(model.viewMode == .icons && model.iconSize == 128)
        model.navigate(to: .folder(fixture.root.appendingPathComponent("ScopeEngine")))
        try await fixture.ready(model)
        #expect(model.viewMode == .details && model.iconSize == 64)
        #expect(fixture.settings.preferences(for: fixture.second).isEmpty)
        model.setViewMode(.gallery)
        model.goBack()
        try await fixture.ready(model)
        #expect(model.viewMode == .icons && model.iconSize == 128)
        model.goForward()
        try await fixture.ready(model)
        #expect(model.viewMode == .gallery && model.iconSize == 64)
        fixture.settings.setViewMode(.list, for: fixture.second)
        model.navigate(to: model.location)
        try await fixture.ready(model)
        #expect(model.viewMode == .list)
        #expect(model.canGoBack && !model.canGoForward)
        let duplicate = fixture.model(at: model.location)
        try await fixture.ready(duplicate)
        #expect(duplicate.viewMode == .list)
        #expect(fixture.settings.defaultViewMode == .details && fixture.settings.defaultIconSize == 64)
    }

    @Test func tabsStayIndependentUntilReloadAndEditsMerge() async throws {
        let fixture = try FolderPreferenceFixture()
        defer { fixture.close() }
        let first = fixture.model()
        let second = fixture.model()
        let other = fixture.model(at: .folder(fixture.root.appendingPathComponent("ScopeEngine")))
        try await fixture.ready(first)
        try await fixture.ready(second)
        try await fixture.ready(other)
        first.setViewMode(.icons)
        first.setIconSize(96)
        #expect(second.viewMode == .details && second.iconSize == 64)
        #expect(other.viewMode == .details && other.iconSize == 64)
        second.reload()
        try await fixture.ready(second)
        #expect(second.viewMode == .icons && second.iconSize == 96)
        fixture.settings.viewTypeScope = .perFolder
        fixture.settings.iconSizeScope = .perFolder
        first.setViewMode(.columns)
        second.setIconSize(128)
        #expect(first.viewMode == .columns && first.iconSize == 96)
        #expect(second.viewMode == .icons && second.iconSize == 128)
        #expect(fixture.settings.preferences(for: fixture.first).viewMode == .columns)
        #expect(fixture.settings.preferences(for: fixture.first).iconSize == 128)
        first.reload()
        try await fixture.ready(first)
        #expect(first.viewMode == .columns && first.iconSize == 128)
    }

    @Test func modeSwitchesAndResetsDoNotPromoteSnapshots() async throws {
        let fixture = try FolderPreferenceFixture()
        defer { fixture.close() }
        let model = fixture.model()
        try await fixture.ready(model)
        fixture.settings.viewTypeScope = .perFolder
        fixture.settings.iconSizeScope = .perFolder
        model.setViewMode(.details)
        model.setIconSize(64)
        #expect(fixture.settings.preferences(for: fixture.first).viewMode == .details)
        #expect(model.canResetIconSize)
        fixture.settings.defaultViewMode = .list
        fixture.settings.defaultIconSize = 96
        #expect(model.viewMode == .details && model.iconSize == 64)
        model.useDefaultViewType()
        model.resetIconSize()
        #expect(model.viewMode == .list && model.iconSize == 96)
        #expect(fixture.settings.preferences(for: fixture.first).isEmpty)
        fixture.settings.viewTypeScope = .global
        fixture.settings.iconSizeScope = .global
        #expect(fixture.settings.defaultViewMode == .list && fixture.settings.defaultIconSize == 96)
        model.resetIconSize()
        #expect(fixture.settings.defaultIconSize == 64)
    }

    @Test func unavailableIdentitiesAndVirtualLocationsStayLocal() async throws {
        let fixture = try FolderPreferenceFixture()
        defer { fixture.close() }
        fixture.settings.viewTypeScope = .perFolder
        fixture.settings.iconSizeScope = .perFolder
        let model = fixture.model(resolver: { _ in nil })
        try await fixture.ready(model)
        model.setViewMode(.icons)
        model.setIconSize(192)
        #expect(model.viewMode == .icons && model.iconSize == 192)
        #expect(fixture.defaults.dictionary(forKey: "folderViewPreferences.v1") == nil)
        model.reload()
        try await fixture.ready(model)
        #expect(model.viewMode == .details && model.iconSize == 64)
        model.navigate(to: .search(SearchQuery(text: "one"), in: fixture.root))
        model.setViewMode(.icons)
        model.setIconSize(128)
        model.replace(with: .search(SearchQuery(text: "two"), in: fixture.root))
        #expect(model.viewMode == .icons && model.iconSize == 128)
        #expect(fixture.settings.defaultViewMode == .details && fixture.settings.defaultIconSize == 64)
        #expect(fixture.settings.preferences(for: fixture.first).isEmpty)
    }

    @Test func lateIdentityResultsAndClosedTabsCannotRestoreOrSave() async throws {
        let fixture = try FolderPreferenceFixture()
        defer { fixture.close() }
        fixture.settings.viewTypeScope = .perFolder
        fixture.settings.setViewMode(.icons, for: fixture.first)
        var pending: CheckedContinuation<FolderPreferenceIdentity?, Never>?
        let model = fixture.model { _ in
            await withCheckedContinuation { pending = $0 }
        }
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(pending != nil)
        model.setViewMode(.gallery)  // Controls/actions are disabled while resolving.
        #expect(fixture.settings.preferences(for: fixture.first).viewMode == .icons)
        model.navigate(to: .tag("ScopePreferenceTest-NoSuchTag"))
        pending?.resume(returning: fixture.first)
        await Task.yield()
        #expect(model.viewMode == .details && model.folderIdentity == nil)
        let closed = fixture.model { _ in
            await withCheckedContinuation { pending = $0 }
        }
        pending = nil
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(pending != nil)
        closed.close()
        pending?.resume(returning: fixture.first)
        await Task.yield()
        #expect(!closed.viewPreferencesReady && closed.folderIdentity == nil)
    }

    @Test func iconControlsUseTabSnapshotsAndOtherStylesKeepTheirSizes() async throws {
        let fixture = try FolderPreferenceFixture()
        defer { fixture.close() }
        let model = fixture.model()
        try await fixture.ready(model)
        model.setViewMode(.icons)
        let controller = BrowserViewController(model: model)
        _ = controller.view
        defer { controller.close() }
        var changes: BrowserModel.Change = []
        model.onChange = {
            changes.formUnion($0)
            controller.update($0)
        }
        model.setIconSize(128)
        #expect((controller.fileView as? IconGridViewController)?.iconSize == 128)
        #expect(changes.isDisjoint(with: [.items, .itemsUpdated, .sort, .location]))
        #expect(IconGridViewController(model: model, style: .list).iconSize == 16)
        #expect(IconGridViewController(model: model, style: .strip).iconSize == 56)
        let grid = try #require(controller.fileView as? IconGridViewController)
        let scroll = try #require(grid.view as? NSScrollView)
        let collection = try #require(scroll.documentView as? IconCollectionView)
        collection.onMagnify?(1.25)
        #expect(model.iconSize == 160)
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let slider = try #require(descendants(controller.view).compactMap { $0 as? NSSlider }.first)
        slider.doubleValue = 96
        slider.sendAction(slider.action, to: slider.target)
        #expect(model.iconSize == 96 && fixture.settings.defaultIconSize == 96)
        fixture.settings.iconSizeScope = .perFolder
        model.setIconSize(128)
        let reset = try #require(
            descendants(controller.view).compactMap { $0 as? NSButton }.first {
                $0.toolTip == "Use Default Icon Size"
            })
        reset.performClick(nil)
        #expect(model.iconSize == 96 && fixture.settings.preferences(for: fixture.first).iconSize == nil)
    }

    @Test func columnsRememberTheRootAndExplicitlyOpeningAChildUsesItsPreference() async throws {
        let fixture = try FolderPreferenceFixture()
        defer { fixture.close() }
        fixture.settings.viewTypeScope = .perFolder
        fixture.settings.setViewMode(.columns, for: fixture.first)
        fixture.settings.setViewMode(.gallery, for: fixture.second)
        let model = fixture.model()
        try await fixture.ready(model)
        let controller = ColumnViewController(model: model)
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        defer { controller.close() }
        model.onChange = { controller.modelDidChange($0) }
        let child = fixture.root.appendingPathComponent("ScopeEngine")
        for _ in 0..<300 {
            if model.state == .loaded, controller.select([child], scroll: false) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.selectedItems.map(\.url) == [child])
        #expect(model.location == .folder(fixture.root) && model.viewMode == .columns)
        #expect(fixture.settings.preferences(for: fixture.second).viewMode == .gallery)
        model.navigate(to: .folder(child))
        try await fixture.ready(model)
        #expect(model.viewMode == .gallery)
    }

    @Test func bulkResetLeavesOpenSnapshotsUntilTheNextNavigation() async throws {
        let fixture = try FolderPreferenceFixture()
        defer { fixture.close() }
        fixture.settings.viewTypeScope = .perFolder
        fixture.settings.iconSizeScope = .perFolder
        fixture.settings.setViewMode(.icons, for: fixture.first)
        fixture.settings.setIconSize(128, for: fixture.first)
        let model = fixture.model()
        try await fixture.ready(model)
        fixture.settings.resetSavedFolderViewTypes()
        fixture.settings.resetSavedFolderIconSizes()
        #expect(model.viewMode == .icons && model.iconSize == 128)
        model.navigate(to: model.location)
        try await fixture.ready(model)
        #expect(model.viewMode == .details && model.iconSize == 64)
    }

    @Test func settingsFormFitsAndScrollsInASmallWindow() async throws {
        let host = NSHostingController(rootView: SettingsView())
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 520, height: 420))
        defer { window.close() }
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(50))
        host.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "folder-view-settings.png")
        #expect(host.view.bounds.width == 520)
        #expect(host.view.bounds.height == 420)
    }
}
