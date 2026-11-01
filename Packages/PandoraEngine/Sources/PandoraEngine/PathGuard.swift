import Foundation
import os

/// Decides which paths the engine may touch.
///
/// Development builds use a restricted guard that only allows the test disks.
/// Every path is resolved through the file system first (symlinks, `/tmp` vs
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

    private static let logger = Logger(subsystem: "com.antonispanos.pandora", category: "PathGuard")

    /// Every absolute path is allowed, for reading and writing.
    public static let unrestricted = PathGuard(policy: .unrestricted, allowsWrites: true)

    /// Every absolute path may be read, but nothing may be changed. The real
    /// Pandora build uses this until the MVP gate in the test plan is met.
    public static let readOnly = PathGuard(policy: .unrestricted, allowsWrites: false)

    /// A guard that only allows paths inside `roots` (the roots themselves included).
    public static func restricted(to roots: [URL]) -> PathGuard {
        PathGuard(policy: .restricted(roots: roots.map { resolveRoot($0.path) }), allowsWrites: true)
    }

    private init(policy: Policy, allowsWrites: Bool) {
        self.policy = policy
        self.allowsWrites = allowsWrites
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
        return try checkLocation(url)
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
        let allowed = roots.contains { root in
            resolved == root || resolved.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        guard allowed else {
            return .failure(PathGuardViolation(path: url.path, resolvedPath: resolved, reason: .outsideAllowedRoots))
        }
        return .success(URL(fileURLWithPath: resolved))
    }

    private func log(_ violation: PathGuardViolation) -> PathGuardViolation {
        Self.logger.fault("Path guard refused \(violation.path, privacy: .public): \(violation.description, privacy: .public)")
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

/// Thrown when the path guard refuses a path. In development builds this means
/// Pandora tried to touch something outside the test disks, which is a bug.
public struct PathGuardViolation: Error, Equatable, CustomStringConvertible, LocalizedError {
    public enum Reason: Sendable, Equatable {
        case outsideAllowedRoots
        case notAFileURL
        case notAbsolute
        case parentReference
        case unresolvable
        case writesDisabled
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
        }
    }

    public var errorDescription: String? { "Path guard: \(description)" }
}
