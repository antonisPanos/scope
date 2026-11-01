import Foundation

/// What macOS privacy settings (TCC) currently let this process reach.
public enum Permissions {
    public enum Status: Sendable, Equatable {
        case granted, denied, unknown
    }

    /// Whether the app has Full Disk Access. macOS offers no API for this, so
    /// it opens the system's own privacy database read-only and closes it
    /// straight away: only Full Disk Access allows that. Nothing is read and no
    /// user file is touched. Meaningless inside the App Sandbox (always denied).
    public static func fullDiskAccess() -> Status {
        let probe = "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(probe, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return .granted
        }
        return errno == EPERM || errno == EACCES ? .denied : .unknown
    }

    /// The Privacy & Security pane where the user grants Full Disk Access.
    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
}
