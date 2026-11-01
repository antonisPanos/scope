import AppKit
import ScopeEngine
import UserNotifications
import os

/// Sends the activity panel's news to Notification Center: a job finished,
/// failed, or is waiting for an answer. Only when it's worth it: Scope isn't
/// the front app, or the job ran a while and the activity drawer is hidden.
/// Jobs the user cancelled, and quick ones while Scope is in front, stay quiet.
@MainActor
final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotifier()

    /// A job this long counts as "a while" even when Scope is in front.
    static let longJob: TimeInterval = 10
    /// Shorter jobs never notify on success, even in the background.
    static let shortJob: TimeInterval = 2

    private let center = UNUserNotificationCenter.current()
    private var lastStates: [UUID: OperationCenter.State] = [:]
    private var askedForPermission = false
    nonisolated private static let logger = Logger(subsystem: "com.antonispanos.scope", category: "Notifications")
    private static let category = "operation"
    private static let conflictID = "conflict"

    private override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [UNNotificationAction(identifier: "show", title: "Show Activity", options: [.foreground])],
                intentIdentifiers: [])
        ])
    }

    /// Asks macOS for permission the first time the user starts a job, so the
    /// prompt shows up next to something they just did.
    func requestPermissionIfNeeded() {
        guard AppSettings.shared.systemNotifications, !askedForPermission else { return }
        askedForPermission = true
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                Self.logger.notice("Notification permission: \(granted)")
            } catch {
                Self.logger.error("Notification permission failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Called with every new set of snapshots; notifies about jobs that just ended.
    func track(_ snapshots: [OperationCenter.Snapshot], drawerVisible: Bool) {
        defer { lastStates = Dictionary(snapshots.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a }) }
        guard AppSettings.shared.systemNotifications else { return }
        for snapshot in snapshots where !snapshot.isActive {
            guard let previous = lastStates[snapshot.id], previous.isActive else { continue }
            let duration = snapshot.started.map { (snapshot.finished ?? Date()).timeIntervalSince($0) } ?? 0
            let inFront = NSApp.isActive
            let failed: Bool
            switch snapshot.state {
            case .done: failed = false
            case .failed: failed = true
            default: continue  // cancelled by the user: they know
            }
            let worthIt =
                inFront
                ? duration >= Self.longJob && !drawerVisible
                : failed || duration >= Self.shortJob
            guard worthIt else { continue }
            post(id: snapshot.id.uuidString, content: content(for: snapshot, duration: duration))
        }
    }

    /// A job is waiting on a "file already exists" choice.
    func conflictWaiting(name: String) {
        guard AppSettings.shared.systemNotifications, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Scope needs an answer"
        content.body = "An item named “\(name)” already exists. The job is paused until you choose."
        content.sound = .default
        content.categoryIdentifier = Self.category
        post(id: Self.conflictID, content: content)
        NSApp.requestUserAttention(.criticalRequest)
    }

    func conflictAnswered() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.conflictID])
    }

    /// The activity drawer opened: what it shows is no longer news.
    func clearDelivered() {
        center.removeAllDeliveredNotifications()
    }

    /// For Settings: whether macOS lets Scope post at all.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    static var settingsURL: URL {
        let id = Bundle.main.bundleIdentifier ?? "com.antonispanos.scope"
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
    }

    // MARK: - Content

    private func content(for snapshot: OperationCenter.Snapshot, duration: TimeInterval) -> UNMutableNotificationContent
    {
        let content = UNMutableNotificationContent()
        content.title = snapshot.title
        content.threadIdentifier = "operations"
        content.categoryIdentifier = Self.category
        content.userInfo = ["operation": snapshot.id.uuidString]
        var lines: [String] = []
        switch snapshot.state {
        case .failed(let message):
            content.subtitle = "Failed"
            lines.append(message)
            content.sound = .defaultCritical
        default:
            content.subtitle = "Done in \(Self.format(duration))"
            if snapshot.progress.bytesTotal > 0 {
                lines.append(ByteCountFormatter.string(fromByteCount: snapshot.progress.bytesTotal, countStyle: .file))
            }
            content.sound = .default
        }
        if !snapshot.skippedEntries.isEmpty {
            lines.append(
                "Skipped \(snapshot.skippedEntries.count) item\(snapshot.skippedEntries.count == 1 ? "" : "s")")
        }
        content.body = lines.joined(separator: " · ")
        return content
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds < 60 ? [.second] : [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(1, seconds.rounded())) ?? "\(Int(seconds))s"
    }

    private func post(id: String, content: UNMutableNotificationContent) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error {
                Self.logger.error("Notification not posted: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        await MainActor.run {
            NSApp.activate()
            (NSApp.delegate as? AppDelegate)?.showActivityInFrontWindow()
        }
    }
}
