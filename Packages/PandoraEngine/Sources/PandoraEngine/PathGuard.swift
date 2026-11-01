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

    private static let logger = Logger(subsystem: "com.antonispanos.pandora", category: "PathGuard")

    /// The guard used by release builds: every absolute path is allowed.
    public static let unrestricted = PathGuard(policy: .unrestricted)

    /// A guard that only allows paths inside `roots` (the roots themselves included).
    public static func restricted(to roots: [URL]) -> PathGuard {
        PathGuard(policy: .restricted(roots: roots.map { resolveRoot($0.path) }))
    }

    private init(policy: Policy) {
        self.policy = policy
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

    /// Checks the item an URL finally points to, following every symlink.
    /// Use it when reading through the item, such as listing a folder.
    @discardableResult
    public func checkTarget(_ url: URL) throws(PathGuardViolation) -> URL {
        try check(url, followFinalSymlink: true)
    }

    private func check(_ url: URL, followFinalSymlink: Bool) throws(PathGuardViolation) -> URL {
        let resolved: String
        do {
            resolved = try Self.resolve(url, followFinalSymlink: followFinalSymlink)
        } catch {
            throw fail(url, resolved: nil, reason: error.reason)
        }

        guard case .restricted(let roots) = policy else {
            return URL(fileURLWithPath: resolved)
        }
        let allowed = roots.contains { root in
            resolved == root || resolved.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        guard allowed else {
            throw fail(url, resolved: resolved, reason: .outsideAllowedRoots)
        }
        return URL(fileURLWithPath: resolved)
    }

    private func fail(_ url: URL, resolved: String?, reason: PathGuardViolation.Reason) -> PathGuardViolation {
        let violation = PathGuardViolation(path: url.path, resolvedPath: resolved, reason: reason)
        Self.logger.fault("Path guard refused \(url.path, privacy: .public): \(violation.description, privacy: .public)")
        return violation
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
        }
    }

    public var errorDescription: String? { "Path guard: \(description)" }
}
