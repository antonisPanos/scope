import AppKit
import ScopeEngine
import SwiftUI
import UserNotifications

/// Settings (Cmd+,). For now: alternatives to Finder's shortcuts, for people
/// used to Windows or Linux file managers. None of them clash with system
/// shortcuts; Finder's own keys keep working alongside.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

struct SettingsView: View {
    @State private var returnOpens = AppSettings.shared.returnOpens
    @State private var f2Renames = AppSettings.shared.f2Renames
    @State private var f5Reloads = AppSettings.shared.f5Reloads
    @State private var optionArrows = AppSettings.shared.optionArrowsNavigate
    @State private var commandXCuts = AppSettings.shared.commandXCuts
    @State private var deleteKey = AppSettings.shared.deleteKey
    @State private var showHidden = AppSettings.shared.showHiddenFiles
    @State private var notifications = AppSettings.shared.systemNotifications
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var fullDiskAccess: Permissions.Status?

    var body: some View {
        Form {
            Section("Shortcuts") {
                Toggle("Return opens the selection (Finder: Return renames)", isOn: $returnOpens)
                    .onChange(of: returnOpens) { AppSettings.shared.returnOpens = returnOpens }
                Toggle("F2 renames", isOn: $f2Renames)
                    .onChange(of: f2Renames) { AppSettings.shared.f2Renames = f2Renames }
                Toggle("F5 reloads the folder", isOn: $f5Reloads)
                    .onChange(of: f5Reloads) { AppSettings.shared.f5Reloads = f5Reloads }
                Toggle("Cmd+X cuts files, and Cmd+V moves them", isOn: $commandXCuts)
                    .onChange(of: commandXCuts) { AppSettings.shared.commandXCuts = commandXCuts }
                Toggle("Option+Left and Option+Right go back and forward", isOn: $optionArrows)
                    .onChange(of: optionArrows) { AppSettings.shared.optionArrowsNavigate = optionArrows }
                Picker("Delete key", selection: $deleteKey) {
                    ForEach(AppSettings.DeleteKey.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: deleteKey) { AppSettings.shared.deleteKey = deleteKey }
                Text(
                    "Finder's own shortcuts (Cmd+Down to open, Cmd+Delete to trash, Cmd+[ and Cmd+] to go back and forward, Cmd+C then Option+Cmd+V to move) always work too."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Files") {
                Toggle("Show hidden files", isOn: $showHidden)
                    .onChange(of: showHidden) { AppSettings.shared.showHiddenFiles = showHidden }
            }
            Section("Notifications") {
                Toggle("Tell me when jobs finish, fail or need an answer", isOn: $notifications)
                    .onChange(of: notifications) {
                        AppSettings.shared.systemNotifications = notifications
                        if notifications { SystemNotifier.shared.requestPermissionIfNeeded() }
                    }
                Text(
                    "Only while Scope is in the background, or for jobs over \(Int(SystemNotifier.longJob)) seconds when the activity drawer is hidden."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if notifications, notificationStatus == .denied {
                    HStack {
                        Text("macOS is blocking Scope's notifications.")
                        Spacer()
                        Button("Open Notification Settings") { NSWorkspace.shared.open(SystemNotifier.settingsURL) }
                    }
                }
            }
            Section("Permissions") {
                if BuildIdentity.current.isDevelopment {
                    Text(
                        "\(BuildIdentity.current.appName) only reaches the test disks, so it needs no extra permissions."
                    )
                    .foregroundStyle(.secondary)
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Full Disk Access")
                            Text(fullDiskAccessText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if fullDiskAccess != .granted {
                            Button("Open Privacy Settings") {
                                NSWorkspace.shared.open(Permissions.fullDiskAccessSettingsURL)
                            }
                        }
                    }
                }
            }
        }
        .task { await refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshPermissions() }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fullDiskAccessText: String {
        switch fullDiskAccess {
        case .granted: "Granted. Scope can see every folder, including Mail and Safari data."
        case .denied: "Not granted. macOS hides some folders, such as Mail and Safari data, and asks before others."
        default: "Checking…"
        }
    }

    /// Re-read when Scope comes back to the front, e.g. from System Settings.
    private func refreshPermissions() async {
        notificationStatus = await SystemNotifier.shared.authorizationStatus()
        guard !BuildIdentity.current.isDevelopment else { return }
        // The main thread never touches disk, not even for a probe.
        fullDiskAccess = await Task.detached { Permissions.fullDiskAccess() }.value
    }
}
