import Foundation
import os

/// Keeps long jobs going while Scope isn't in front: no App Nap, no idle
/// system sleep, no automatic or sudden termination, for as long as any job
/// is queued or running. Closing the lid still sleeps the Mac, as it should.
@MainActor
final class KeepAlive {
    private var activity: NSObjectProtocol?
    private static let logger = Logger(subsystem: "com.antonispanos.scope", category: "Operations")

    func update(busy: Bool) {
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "Copying, moving or deleting files")
            Self.logger.notice("Keeping awake while jobs run")
        } else if !busy, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
            Self.logger.notice("Jobs done; sleep and App Nap allowed again")
        }
    }
}
