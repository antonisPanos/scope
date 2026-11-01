import os
import PandoraEngine
import SwiftUI

/// The M0 window: shows what kind of build this is and lists the test disk
/// through the engine, so the sandbox and the path guard can be checked by eye.
/// M1 replaces it with the real browser window.
struct StatusView: View {
    let engine: FileEngine
    @State private var listing: Result<[FileItem], Error>?
    @State private var guardProbe: String?

    private let identity = BuildIdentity.current
    private let testDisk = BuildIdentity.testDiskRoots[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(identity.appName).font(.largeTitle.bold())
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Build", identity.isDevelopment ? "Development" : "Release")
                row("App Sandbox", identity.isSandboxed ? "On" : "Off")
                row("Path guard", identity.isDevelopment
                    ? "Test disks only: " + identity.allowedRoots.map(\.path).joined(separator: ", ")
                    : identity.pathGuard.allowsWrites ? "Off" : "Read-only: every change is refused")
                if let guardProbe { row("Guard check", guardProbe) }
            }
            Divider()
            Text(testDisk.path).font(.headline)
            listingView
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360, alignment: .topLeading)
        .task { await load() }
    }

    @ViewBuilder private var listingView: some View {
        switch listing {
        case nil:
            ProgressView().controlSize(.small)
        case .failure(let error):
            Text(error.localizedDescription).foregroundStyle(.secondary)
            if !FileManager.default.fileExists(atPath: testDisk.path) {
                Text("Run scripts/testdisk.sh create to make the test disk.").foregroundStyle(.secondary)
            }
        case .success(let items):
            List(items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { item in
                Label(item.name, systemImage: item.isSymbolicLink ? "arrow.turn.up.right"
                      : item.isDirectory ? "folder" : "doc")
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private static let logger = Logger(subsystem: "com.antonispanos.pandora", category: "Status")

    private func load() async {
        defer {
            let listed = (try? listing?.get().count).map(String.init) ?? "failed"
            Self.logger.notice("Startup check: sandbox \(identity.isSandboxed), test disk items \(listed, privacy: .public), guard \(guardProbe ?? "n/a", privacy: .public)")
        }
        do {
            listing = .success(try await engine.contentsOfDirectory(at: testDisk))
        } catch {
            listing = .failure(error)
        }
        // Prove the guard is live: the real home folder must be refused in
        // development builds. (NSHomeDirectory() is the sandbox container.)
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        do {
            _ = try await engine.contentsOfDirectory(at: URL(fileURLWithPath: home))
            guardProbe = identity.isDevelopment ? "FAILED: home folder was readable" : nil
        } catch let violation as PathGuardViolation {
            guardProbe = "Home folder refused (\(violation.reason))"
        } catch {
            guardProbe = identity.isDevelopment ? "Home folder unreadable: \(error.localizedDescription)" : nil
        }
    }
}
