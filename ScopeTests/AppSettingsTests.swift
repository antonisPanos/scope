import Foundation
import ScopeEngine
import Testing

@testable import Scope

/// Settings read and written through a throwaway defaults suite, so tests
/// never change the settings Scope Dev runs with.
@MainActor struct AppSettingsTests {
    let suiteName = "ScopeTests-\(UUID().uuidString)"

    private func withSettings(_ body: (AppSettings) throws -> Void) throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(AppSettings(defaults: defaults))
    }

    @Test func startsFromTheDefaults() throws {
        try withSettings { settings in
            #expect(!settings.showHiddenFiles)
            #expect(settings.lastViewMode == .details)
            #expect(settings.iconSize == 64)
            #expect(settings.favoritePaths.isEmpty)
        }
    }

    @Test func keepsWhatIsSetWithoutTouchingTheAppsOwnSettings() throws {
        let before = UserDefaults.standard.dictionaryRepresentation()["favoritePaths"] as? [String]
        try withSettings { settings in
            settings.favoritePaths = ["/Volumes/ScopeTest/a"]
            settings.iconSize = 1000
            settings.lastViewMode = .icons
            #expect(settings.favoritePaths == ["/Volumes/ScopeTest/a"])
            #expect(settings.iconSize == AppSettings.iconSizes.upperBound)
            #expect(settings.lastViewMode == .icons)
        }
        #expect(UserDefaults.standard.dictionaryRepresentation()["favoritePaths"] as? [String] == before)
    }
}
