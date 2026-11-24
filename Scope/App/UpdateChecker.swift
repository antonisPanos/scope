import Foundation
import os

struct ReleaseVersion: Comparable, CustomStringConvertible {
    private let components: [Int]

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var components: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0, part == String(number) else { return nil }
            components.append(number)
        }
        self.components = components
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    var releasePage: URL {
        URL(string: "https://github.com/antonisPanos/scope/releases/tag/v\(self)")!
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

@MainActor
final class UpdateChecker {
    private static let logger = Logger(subsystem: "com.antonispanos.scope", category: "Updates")
    private static let lastAttemptKey = "updates.lastAttempt"
    private static let latestVersionKey = "updates.latestVersion"
    private static let dismissedVersionsKey = "updates.dismissedVersions"

    private let installedVersion: ReleaseVersion
    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetchLatest: () async throws -> ReleaseVersion
    private var isChecking = false

    init(
        installedVersion: ReleaseVersion, defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        fetchLatest: @escaping () async throws -> ReleaseVersion = UpdateChecker.fetchLatestRelease
    ) {
        self.installedVersion = installedVersion
        self.defaults = defaults
        self.now = now
        self.fetchLatest = fetchLatest
    }

    var availableVersion: ReleaseVersion? {
        guard let saved = defaults.string(forKey: Self.latestVersionKey),
            let latest = ReleaseVersion(saved), latest > installedVersion,
            !dismissedVersions.contains(saved)
        else { return nil }
        return latest
    }

    func dismiss(_ version: ReleaseVersion) {
        var dismissed = dismissedVersions
        if dismissed.insert(version.description).inserted {
            defaults.set(dismissed.sorted(), forKey: Self.dismissedVersionsKey)
        }
    }

    private var dismissedVersions: Set<String> {
        Set(defaults.stringArray(forKey: Self.dismissedVersionsKey) ?? [])
    }

    func checkIfDue() async {
        guard !isChecking else { return }
        let attempt = now()
        if let last = defaults.object(forKey: Self.lastAttemptKey) as? Date,
            attempt >= last, attempt.timeIntervalSince(last) < 3_600
        {
            return
        }

        // A failed request counts too. Record the attempt before suspending.
        defaults.set(attempt, forKey: Self.lastAttemptKey)
        isChecking = true
        defer { isChecking = false }
        do {
            let latest = try await fetchLatest()
            defaults.set(latest.description, forKey: Self.latestVersionKey)
        } catch {
            Self.logger.debug("Release check failed: \(String(describing: error))")
        }
    }

    private struct ReleaseResponse: Decodable {
        struct Asset: Decodable { let name: String }

        let tag: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case draft, prerelease, assets
        }
    }

    private enum CheckError: Error {
        case unexpectedStatus(Int?)
        case invalidRelease
    }

    static func releaseVersion(from data: Data, statusCode: Int?) throws -> ReleaseVersion {
        guard statusCode == 200 else { throw CheckError.unexpectedStatus(statusCode) }
        let release = try JSONDecoder().decode(ReleaseResponse.self, from: data)
        guard !release.draft, !release.prerelease, release.tag.hasPrefix("v"),
            let version = ReleaseVersion(String(release.tag.dropFirst())),
            release.assets.contains(where: { $0.name == "Scope-\(version).dmg" })
        else { throw CheckError.invalidRelease }
        return version
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()

    private static func fetchLatestRelease() async throws -> ReleaseVersion {
        let url = URL(string: "https://api.github.com/repos/antonisPanos/scope/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        return try releaseVersion(from: data, statusCode: (response as? HTTPURLResponse)?.statusCode)
    }
}
