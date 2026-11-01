import Foundation
import PandoraEngine

/// Which kind of build this is, and the engine that goes with it.
///
/// Development builds ("Pandora Dev") compile with PANDORA_DEV and may only
/// touch the test disks; the path guard enforces that on every operation,
/// independently of the App Sandbox. Release builds ("Pandora") may read
/// anything but change nothing until PANDORA_ALLOW_WRITES is added to
/// Config/Pandora.xcconfig, a deliberate step for after the MVP gate.
struct BuildIdentity {
    let appName: String
    let isDevelopment: Bool
    let isSandboxed: Bool
    let allowedRoots: [URL]

    /// The volumes made by scripts/testdisk.sh. Keep in sync with the script
    /// and with Config/PandoraDev.entitlements.
    static let testDiskRoots = [
        URL(fileURLWithPath: "/Volumes/PandoraTest"),
        URL(fileURLWithPath: "/Volumes/PandoraTest2"),
        URL(fileURLWithPath: "/Volumes/PandoraTestCS"),
    ]

    static let current: BuildIdentity = {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Pandora"
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #if PANDORA_DEV
        return BuildIdentity(appName: name, isDevelopment: true, isSandboxed: sandboxed, allowedRoots: testDiskRoots)
        #else
        return BuildIdentity(appName: name, isDevelopment: false, isSandboxed: sandboxed, allowedRoots: [])
        #endif
    }()

    var pathGuard: PathGuard {
        if isDevelopment { return .restricted(to: allowedRoots) }
        #if PANDORA_ALLOW_WRITES
        return .unrestricted
        #else
        return .readOnly
        #endif
    }

    func makeEngine() -> FileEngine {
        FileEngine(pathGuard: pathGuard)
    }
}
