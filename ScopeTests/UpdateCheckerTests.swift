import Foundation
import Testing

@testable import Scope

@MainActor struct UpdateCheckerTests {
    private let installed = ReleaseVersion("0.8.0")!

    @Test(arguments: ["0.10.0", "0.8.10", "1.0.0"])
    func comparesVersionComponentsNumerically(_ value: String) throws {
        let version = try #require(ReleaseVersion(value))
        #expect(version > installed)
    }

    @Test(arguments: ["0.8", "0.8.", "0..8.0", "0.08.0", "0.-1.0", "0.8.0-beta.1", "0.8.0+1"])
    func rejectsMalformedVersions(_ value: String) {
        #expect(ReleaseVersion(value) == nil)
    }

    private func releaseJSON(
        tag: String = "v0.10.0", asset: String = "Scope-0.10.0.dmg", draft: Bool = false, prerelease: Bool = false
    ) -> Data {
        Data(
            """
            {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease),"assets":[{"name":"\(asset)"}]}
            """.utf8)
    }

    @Test func readsStableReleaseWithMatchingInstaller() throws {
        let version = try UpdateChecker.releaseVersion(from: releaseJSON(), statusCode: 200)
        #expect(version.description == "0.10.0")
        #expect(version.releasePage.absoluteString == "https://github.com/antonisPanos/scope/releases/tag/v0.10.0")
    }

    @Test func ignoresUnusableResponses() {
        for data in [
            releaseJSON(asset: "Scope-0.10.0.dmg.sha256"), releaseJSON(draft: true), releaseJSON(prerelease: true),
            releaseJSON(tag: "0.10.0"), releaseJSON(tag: "v0.10.0-beta.1"), Data("not JSON".utf8),
        ] {
            #expect(throws: (any Error).self) { try UpdateChecker.releaseVersion(from: data, statusCode: 200) }
        }
        for status in [403, 404, 429, 500] {
            #expect(throws: (any Error).self) {
                try UpdateChecker.releaseVersion(from: releaseJSON(), statusCode: status)
            }
        }
    }

    @Test func persistsTheLastAttemptAndVerifiedReleaseAcrossRelaunches() async throws {
        let name = "ScopeTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let next = try #require(ReleaseVersion("0.10.0"))
        var now = Date(timeIntervalSince1970: 10_000)
        var attempts = 0
        let first = UpdateChecker(installedVersion: installed, defaults: defaults, now: { now }) {
            attempts += 1
            return next
        }
        #expect(first.availableVersion == nil)
        await first.checkIfDue()
        #expect(first.availableVersion == next)

        let reopenedDefaults = try #require(UserDefaults(suiteName: name))
        let reopened = UpdateChecker(installedVersion: installed, defaults: reopenedDefaults, now: { now }) {
            attempts += 1
            return installed
        }
        now.addTimeInterval(3_599)
        await reopened.checkIfDue()
        #expect(attempts == 1)
        #expect(reopened.availableVersion == next)

        now.addTimeInterval(1)
        await reopened.checkIfDue()
        #expect(attempts == 2)
        #expect(reopened.availableVersion == nil)
    }

    @Test func dismissalSurvivesRelaunchAndTheSameReleaseCanBeCheckedAgain() async throws {
        let name = "ScopeTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let second = try #require(ReleaseVersion("0.10.0"))
        let first = try #require(ReleaseVersion("0.9.0"))
        var now = Date(timeIntervalSince1970: 10_000)
        var latest = first
        let original = UpdateChecker(installedVersion: installed, defaults: defaults, now: { now }) { latest }
        await original.checkIfDue()
        original.dismiss(first)
        #expect(original.availableVersion == nil)

        let reopened = UpdateChecker(installedVersion: installed, defaults: defaults, now: { now }) { latest }
        now.addTimeInterval(3_600)
        await reopened.checkIfDue()
        #expect(reopened.availableVersion == nil)

        latest = second
        now.addTimeInterval(3_600)
        await reopened.checkIfDue()
        #expect(reopened.availableVersion == second)

        reopened.dismiss(second)
        latest = first
        now.addTimeInterval(3_600)
        await reopened.checkIfDue()
        #expect(reopened.availableVersion == nil)
    }

    @Test func offlineAttemptsAreThrottledAndPreserveTheLastVerifiedRelease() async throws {
        let name = "ScopeTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let next = try #require(ReleaseVersion("0.10.0"))
        var now = Date(timeIntervalSince1970: 10_000)
        var isOffline = true
        var attempts = 0
        let checker = UpdateChecker(installedVersion: installed, defaults: defaults, now: { now }) {
            attempts += 1
            if isOffline { throw URLError(.notConnectedToInternet) }
            return next
        }

        await checker.checkIfDue()
        await checker.checkIfDue()
        #expect(attempts == 1)
        #expect(checker.availableVersion == nil)

        isOffline = false
        now.addTimeInterval(3_600)
        await checker.checkIfDue()
        #expect(attempts == 2)
        #expect(checker.availableVersion == next)

        isOffline = true
        now.addTimeInterval(3_600)
        await checker.checkIfDue()
        #expect(attempts == 3)
        #expect(checker.availableVersion == next)
    }

    @Test func overlappingTriggersShareTheInFlightCheck() async throws {
        let name = "ScopeTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 10_000)
        var attempts = 0
        let (started, signal) = AsyncStream<Void>.makeStream()
        var finish: CheckedContinuation<ReleaseVersion, Never>?
        let checker = UpdateChecker(installedVersion: installed, defaults: defaults, now: { now }) {
            attempts += 1
            guard attempts == 1 else { return installed }
            return await withCheckedContinuation {
                finish = $0
                signal.yield()
            }
        }

        let first = Task { await checker.checkIfDue() }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        await checker.checkIfDue()
        now.addTimeInterval(3_600)
        await checker.checkIfDue()
        #expect(attempts == 1)
        finish?.resume(returning: installed)
        await first.value
        signal.finish()
    }
}
