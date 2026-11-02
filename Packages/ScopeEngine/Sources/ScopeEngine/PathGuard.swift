import Foundation
import os

/// Decides which paths the engine may touch.
///
/// Development builds read anywhere but change files only inside one scratch
/// folder (`writesOnlyUnder`); engine tests restrict reads and writes to their
/// own temporary folders (`restricted`). Every path is resolved through the file system first (symlinks, `/tmp` vs
/// `/private/tmp`, and so on), so a symlink or a dropped-in file can't lead the
/// engine outside the allowed roots. Anything that can't be resolved cleanly is
/// refused: the guard fails closed.
public struct PathGuard: Sendable {
    public enum Policy: Sendable, Equatable {
        case unrestricted
        case restricted(roots: [String])
    }

    public let policy: Policy

    /// Whether operations that change the disk are allowed at all. When false,
    /// every write is refused, wherever it points.
    public let allowsWrites: Bool

    /// When set, writes are allowed only inside these folders (resolved paths,
    /// the folders themselves included), whatever `policy` allows for reading.
    public let writeRoots: [String]?

    /// Items that may never be renamed, moved or trashed themselves (what is
    /// inside them can be), stored lowercased and precomposed so a differently
    /// cased or normalized spelling still matches. Volume roots are refused too.
    let protectedItems: Set<String>

    private static let logger = Logger(subsystem: "com.antonispanos.scope", category: "PathGuard")

    /// Every absolute path is allowed, for reading and writing, except that
    /// the protected items can't be renamed, moved or trashed.
    public static let unrestricted = PathGuard(policy: .unrestricted, allowsWrites: true)

    /// Every absolute path may be read, but nothing may be changed.
    public static let readOnly = PathGuard(policy: .unrestricted, allowsWrites: false)

    /// A guard that only allows paths inside `roots` (the roots themselves included).
    public static func restricted(to roots: [URL]) -> PathGuard {
        PathGuard(policy: .restricted(roots: roots.map { resolveRoot($0.path) }), allowsWrites: true)
    }

    /// Every absolute path may be read, but changes are allowed only inside
    /// `roots`. The roots themselves may be created, but never renamed, moved
    /// or trashed. Scope Dev uses this with its scratch folder.
    public static func writesOnlyUnder(_ roots: [URL]) -> PathGuard {
        let resolved = roots.map { resolveRoot($0.path) }
        return PathGuard(
            policy: .unrestricted, allowsWrites: true, writeRoots: resolved,
            protectedItems: defaultProtectedItems + resolved)
    }

    private init(
        policy: Policy, allowsWrites: Bool, writeRoots: [String]? = nil,
        protectedItems: [String] = PathGuard.defaultProtectedItems
    ) {
        self.policy = policy
        self.allowsWrites = allowsWrites
        self.writeRoots = writeRoots
        self.protectedItems = Set(protectedItems.map(Self.protectionKey))
    }

    /// Folders macOS and the user's account need in place, as Finder protects
    /// them: system folders, the home folder and its standard folders.
    static let defaultProtectedItems: [String] = {
        let system = [
            "/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/Network", "/cores", "/opt",
            "/bin", "/sbin", "/usr", "/etc", "/tmp", "/var", "/private", "/private/etc", "/private/tmp",
            "/private/var",
        ]
        let home = userHome
        let standard = [
            "", "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures",
            "Public", ".Trash",
        ]
        return system + standard.map { $0.isEmpty ? home : home + "/" + $0 }
    }()

    /// The account's real home folder, also when sandboxed (where
    /// NSHomeDirectory points into the container).
    private static let userHome: String = {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return resolveRoot(String(cString: directory))
        }
        return resolveRoot(NSHomeDirectory())
    }()

    static func protectionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    public var isRestricted: Bool {
        if case .restricted = policy { return true }
        return false
    }

    /// Checks where an item lives without following a symlink at its last
    /// component. Use it for operations on the item itself: rename, move,
    /// trash, copy (symlinks are copied as links), create.
    @discardableResult
    public func checkLocation(_ url: URL) throws(PathGuardViolation) -> URL {
        try check(url, followFinalSymlink: false)
    }

    /// Like `checkLocation`, for an item about to be created, changed, moved or
    /// trashed. Refused outright when the guard doesn't allow writes.
    @discardableResult
    public func checkWriteLocation(_ url: URL) throws(PathGuardViolation) -> URL {
        guard allowsWrites else { throw fail(url, resolved: nil, reason: .writesDisabled) }
        let resolved = try checkLocation(url)
        if let writeRoots, !Self.isInside(resolved.path, anyOf: writeRoots) {
            throw fail(url, resolved: resolved.path, reason: .outsideWritableFolders)
        }
        return resolved
    }

    /// Like `checkWriteLocation`, for an item in a Trash that Scope is putting
    /// back (undoing a trash). Taking an item out of a Trash changes nothing
    /// the user hasn't already thrown away, so a guard that only writes in its
    /// scratch folder allows it; where it lands still passes
    /// `checkWriteLocation`.
    @discardableResult
    public func checkPutBack(_ url: URL) throws(PathGuardViolation) -> URL {
        guard allowsWrites else { throw fail(url, resolved: nil, reason: .writesDisabled) }
        let resolved = try checkLocation(url)
        if let writeRoots, !Self.isInside(resolved.path, anyOf: writeRoots), !Self.isInTrash(resolved.path) {
            throw fail(url, resolved: resolved.path, reason: .outsideWritableFolders)
        }
        return resolved
    }

    /// Whether `path` is an item inside the user's Trash (~/.Trash) or a
    /// volume's (.Trashes/<uid>), not the Trash folder itself.
    static func isInTrash(_ path: String) -> Bool {
        if path.hasPrefix(userHome + "/.Trash/") { return true }
        guard let range = path.range(of: "/.Trashes/") else { return false }
        let rest = path[range.upperBound...].split(separator: "/", maxSplits: 1)
        return rest.count == 2 && rest[0].allSatisfy(\.isNumber) && !rest[1].isEmpty
    }

    /// Like `checkWriteLocation`, for an existing item about to be renamed,
    /// moved or trashed. Also refuses the items macOS needs in place: volume
    /// roots, system folders, the home folder and its standard folders.
    @discardableResult
    public func checkModifiable(_ url: URL) throws(PathGuardViolation) -> URL {
        let resolved = try checkWriteLocation(url)
        if protectedItems.contains(Self.protectionKey(resolved.path)) || Self.isVolumeRoot(resolved.path) {
            throw fail(url, resolved: resolved.path, reason: .protectedItem)
        }
        return resolved
    }

    /// Whether `path` is the root of a mounted volume: "/", a folder the file
    /// system reports as a mount point, or one on a different device than its
    /// parent.
    private static func isVolumeRoot(_ path: String) -> Bool {
        if path == "/" { return true }
        var item = stat()
        guard lstat(path, &item) == 0, item.st_mode & S_IFMT == S_IFDIR else { return false }
        var volume = statfs()
        if statfs(path, &volume) == 0 {
            let mountPoint = withUnsafeBytes(of: volume.f_mntonname) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if mountPoint == path || realpath(mountPoint) == path { return true }
        }
        var parent = stat()
        guard lstat((path as NSString).deletingLastPathComponent, &parent) == 0 else { return false }
        return item.st_dev != parent.st_dev
    }

    /// Checks the item an URL finally points to, following every symlink.
    /// Use it when reading through the item, such as listing a folder.
    @discardableResult
    public func checkTarget(_ url: URL) throws(PathGuardViolation) -> URL {
        try check(url, followFinalSymlink: true)
    }

    /// Whether the item an URL points to may be read, without logging a
    /// refusal. Use it to decide what the UI offers (a sidebar entry, a search
    /// result); actual operations still go through the checks above.
    public func permits(_ url: URL) -> Bool {
        if case .success = evaluate(url, followFinalSymlink: true) { return true }
        return false
    }

    private func check(_ url: URL, followFinalSymlink: Bool) throws(PathGuardViolation) -> URL {
        switch evaluate(url, followFinalSymlink: followFinalSymlink) {
        case .success(let resolved): return resolved
        case .failure(let violation): throw log(violation)
        }
    }

    private func evaluate(_ url: URL, followFinalSymlink: Bool) -> Result<URL, PathGuardViolation> {
        let resolved: String
        do {
            resolved = try Self.resolve(url, followFinalSymlink: followFinalSymlink)
        } catch {
            return .failure(PathGuardViolation(path: url.path, resolvedPath: nil, reason: error.reason))
        }

        guard case .restricted(let roots) = policy else {
            return .success(URL(fileURLWithPath: resolved))
        }
        guard Self.isInside(resolved, anyOf: roots) else {
            return .failure(PathGuardViolation(path: url.path, resolvedPath: resolved, reason: .outsideAllowedRoots))
        }
        return .success(URL(fileURLWithPath: resolved))
    }

    private static func isInside(_ path: String, anyOf roots: [String]) -> Bool {
        roots.contains { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    private func log(_ violation: PathGuardViolation) -> PathGuardViolation {
        Self.logger.fault(
            "Path guard refused \(violation.path, privacy: .public): \(violation.description, privacy: .public)")
        return violation
    }

    private func fail(_ url: URL, resolved: String?, reason: PathGuardViolation.Reason) -> PathGuardViolation {
        log(PathGuardViolation(path: url.path, resolvedPath: resolved, reason: reason))
    }

    // MARK: - Resolution

    private struct ResolveError: Error {
        let reason: PathGuardViolation.Reason
    }

    private static func resolveRoot(_ path: String) -> String {
        realpath(path) ?? (path as NSString).standardizingPath
    }

    /// Resolves `url` to a canonical absolute path. The existing part of the
    /// path goes through realpath(3); a part that doesn't exist yet (the
    /// target of a create or copy) is appended as is, but may not contain
    /// `.` or `..`.
    private static func resolve(_ url: URL, followFinalSymlink: Bool) throws(ResolveError) -> String {
        guard url.isFileURL else { throw ResolveError(reason: .notAFileURL) }
        let path = url.path
        guard path.hasPrefix("/") else { throw ResolveError(reason: .notAbsolute) }

        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.contains("..") { throw ResolveError(reason: .parentReference) }
        components.removeAll { $0 == "." }
        guard let last = components.popLast() else { return "/" }

        let parent = "/" + components.joined(separator: "/")
        let resolvedParent = try resolveExistingPrefix(parent)
        let candidate = resolvedParent == "/" ? "/" + last : resolvedParent + "/" + last

        if followFinalSymlink, lstatExists(candidate) {
            guard let full = realpath(candidate) else { throw ResolveError(reason: .unresolvable) }
            return full
        }
        return candidate
    }

    /// Resolves the longest prefix of `path` that exists and appends the rest.
    private static func resolveExistingPrefix(_ path: String) throws(ResolveError) -> String {
        if let resolved = realpath(path) { return resolved }
        // realpath fails for a missing path, and for a dangling symlink. Refuse
        // the latter: we can't tell where it would lead.
        if lstatExists(path) { throw ResolveError(reason: .unresolvable) }
        let ns = path as NSString
        let parent = ns.deletingLastPathComponent
        guard parent != path else { throw ResolveError(reason: .unresolvable) }
        let resolvedParent = try resolveExistingPrefix(parent)
        return resolvedParent == "/" ? "/" + ns.lastPathComponent : resolvedParent + "/" + ns.lastPathComponent
    }

    private static func lstatExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Thrown when the path guard refuses a path.
public struct PathGuardViolation: Error, Equatable, CustomStringConvertible, LocalizedError {
    public enum Reason: Sendable, Equatable {
        case outsideAllowedRoots
        case notAFileURL
        case notAbsolute
        case parentReference
        case unresolvable
        case writesDisabled
        case outsideWritableFolders
        case protectedItem
    }

    public let path: String
    public let resolvedPath: String?
    public let reason: Reason

    public var description: String {
        switch reason {
        case .outsideAllowedRoots:
            "\(path) is outside the allowed folders (resolves to \(resolvedPath ?? path))"
        case .notAFileURL:
            "\(path) is not a file URL"
        case .notAbsolute:
            "\(path) is not an absolute path"
        case .parentReference:
            "\(path) contains '..'"
        case .unresolvable:
            "\(path) could not be resolved (a dangling or looping symlink)"
        case .writesDisabled:
            "\(path) can't be changed: this build is read-only"
        case .outsideWritableFolders:
            "\(path) can't be changed: this build only changes files in its scratch folder"
        case .protectedItem:
            "\((path as NSString).lastPathComponent) can't be renamed, moved or trashed because macOS needs it"
        }
    }

    public var errorDescription: String? { "Path guard: \(description)" }
}
