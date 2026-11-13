import Foundation
import ScopeEngine
import Synchronization

/// Which kind of build this is, and the engine that goes with it.
///
/// Neither build runs in the App Sandbox. Development builds ("Scope Dev")
/// compile with SCOPE_DEV: ordinary launches read anywhere but change files
/// only inside the scratch folder. An explicit stress launch is confined to
/// the verified volumes of one disk image instead.
/// Production builds ("Scope") enable SCOPE_ALLOW_WRITES by default and
/// use normal macOS permissions. A local configuration may omit that flag
/// for a read-only build; Scope Dev always keeps its scratch restriction.
struct BuildIdentity {
    let appName: String
    let isDevelopment: Bool
    let isSandboxed: Bool

    static let current: BuildIdentity = {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Scope"
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #if SCOPE_DEV
        return BuildIdentity(appName: name, isDevelopment: true, isSandboxed: sandboxed)
        #else
        return BuildIdentity(appName: name, isDevelopment: false, isSandboxed: sandboxed)
        #endif
    }()

    /// The user's real home folder. NSHomeDirectory() is the sandbox
    /// container in sandboxed builds.
    static let realHome: URL = {
        if let entry = getpwuid(getuid()) { return URL(fileURLWithPath: String(cString: entry.pointee.pw_dir)) }
        return URL(fileURLWithPath: NSHomeDirectory())
    }()

    /// The one folder Scope Dev may change files in. Go > Scratch Folder
    /// creates it.
    static let scratchFolder = realHome.appendingPathComponent("ScopeScratch", isDirectory: true)

    private static let stressAccess = Mutex<StressImageAccess?>(nil)

    static var isStressRequested: Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--scope-stress-") }
    }

    static var stress: StressImageAccess? { stressAccess.withLock { $0 } }

    static func installStress(_ access: StressImageAccess) {
        stressAccess.withLock { $0 = access }
    }

    static func stressOptions() throws -> (image: URL, source: UUID, target: UUID) {
        let args = ProcessInfo.processInfo.arguments
        let keys = ["--scope-stress-image", "--scope-stress-source", "--scope-stress-target"]
        guard args.count == 7, Set(stride(from: 1, to: args.count, by: 2).map { args[$0] }) == Set(keys),
            let source = UUID(uuidString: args[4]), let target = UUID(uuidString: args[6]),
            args[1] == keys[0], args[3] == keys[1], args[5] == keys[2],
            args[2].hasPrefix("/")
        else { throw StressImageError.invalidConfiguration }
        return (URL(fileURLWithPath: args[2]), source, target)
    }

    /// Where a new window opens.
    var startFolder: URL { Self.isStressRequested ? (Self.stress?.source ?? Self.realHome) : Self.realHome }

    var pathGuard: PathGuard {
        if isDevelopment {
            if Self.isStressRequested { return Self.stress?.pathGuard ?? .denyAll }
            return .writesOnlyUnder([Self.scratchFolder])
        }
        #if SCOPE_ALLOW_WRITES
        return .unrestricted
        #else
        return .readOnly
        #endif
    }

    /// The archive service in Contents/XPCServices, by its bundle identifier
    /// (set in Config/ScopeArchiveService.xcconfig).
    static var archiveServiceName: String {
        #if SCOPE_DEV
        "com.antonispanos.scope.dev.archive-service"
        #else
        "com.antonispanos.scope.archive-service"
        #endif
    }

    func makeEngine() -> FileEngine {
        var engine = FileEngine(pathGuard: pathGuard)
        // Archives are parsed in the sandboxed archive service, never in the app.
        engine.archiveReaders = XPCArchiveReaders.embedded(Self.archiveServiceName)
        engine.archiveWriters = XPCArchiveWriters.embedded(Self.archiveServiceName)
        return engine
    }
}
