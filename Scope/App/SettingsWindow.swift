import AppKit
import SwiftUI

/// Settings (Cmd+,). For now: alternatives to Finder's shortcuts, for people
/// used to Windows or Linux file managers. None of them clash with system
/// shortcuts; Finder's own keys keep working alongside.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
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
    @State private var deleteKey = AppSettings.shared.deleteKey
    @State private var showHidden = AppSettings.shared.showHiddenFiles

    var body: some View {
        Form {
            Section("Shortcuts") {
                Toggle("Return opens the selection (Finder: Return renames)", isOn: $returnOpens)
                    .onChange(of: returnOpens) { AppSettings.shared.returnOpens = returnOpens }
                Toggle("F2 renames", isOn: $f2Renames)
                    .onChange(of: f2Renames) { AppSettings.shared.f2Renames = f2Renames }
                Toggle("F5 reloads the folder", isOn: $f5Reloads)
                    .onChange(of: f5Reloads) { AppSettings.shared.f5Reloads = f5Reloads }
                Toggle("Option+Left and Option+Right go back and forward", isOn: $optionArrows)
                    .onChange(of: optionArrows) { AppSettings.shared.optionArrowsNavigate = optionArrows }
                Picker("Delete key", selection: $deleteKey) {
                    ForEach(AppSettings.DeleteKey.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: deleteKey) { AppSettings.shared.deleteKey = deleteKey }
                Text("Finder's own shortcuts (Cmd+Down to open, Cmd+Delete to trash, Cmd+[ and Cmd+] to go back and forward) always work too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Files") {
                Toggle("Show hidden files", isOn: $showHidden)
                    .onChange(of: showHidden) { AppSettings.shared.showHiddenFiles = showHidden }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
