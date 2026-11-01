import Foundation
import ScopeEngine

/// Which kind of build this is, and the engine that goes with it.
///
/// Development builds ("Scope Dev") compile with SCOPE_DEV and may only
/// touch the test disks; the path guard enforces that on every operation,
/// independently of the App Sandbox. Release builds ("Scope") may read
/// anything but change nothing until SCOPE_ALLOW_WRITES is added to
/// Config/Scope.xcconfig, a deliberate step for after the MVP gate.
struct BuildIdentity {
    let appName: String
    let isDevelopment: Bool
    let isSandboxed: Bool
    let allowedRoots: [URL]

    /// The volumes made by scripts/testdisk.sh. Keep in sync with the script
    /// and with Config/ScopeDev.entitlements.
    static let testDiskRoots = [
        URL(fileURLWithPath: "/Volumes/ScopeTest"),
        URL(fileURLWithPath: "/Volumes/ScopeTest2"),
        URL(fileURLWithPath: "/Volumes/ScopeTestCS"),
    ]

    static let current: BuildIdentity = {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Scope"
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #if SCOPE_DEV
        return BuildIdentity(appName: name, isDevelopment: true, isSandboxed: sandboxed, allowedRoots: testDiskRoots)
        #else
        return BuildIdentity(appName: name, isDevelopment: false, isSandboxed: sandboxed, allowedRoots: [])
        #endif
    }()

    /// The user's real home folder. NSHomeDirectory() is the sandbox
    /// container in sandboxed builds.
    static let realHome: URL = {
        if let entry = getpwuid(getuid()) { return URL(fileURLWithPath: String(cString: entry.pointee.pw_dir)) }
        return URL(fileURLWithPath: NSHomeDirectory())
    }()

    /// Where a new window opens: the test disk in development builds, home otherwise.
    var startFolder: URL {
        isDevelopment ? Self.testDiskRoots[0] : Self.realHome
    }

    var pathGuard: PathGuard {
        if isDevelopment { return .restricted(to: allowedRoots) }
        #if SCOPE_ALLOW_WRITES
        return .unrestricted
        #else
        return .readOnly
        #endif
    }

    func makeEngine() -> FileEngine {
        FileEngine(pathGuard: pathGuard)
    }
}
