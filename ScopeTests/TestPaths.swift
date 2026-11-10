import Foundation

/// Folders in this checkout that read-only browsing tests list.
enum TestPaths {
    /// The checkout's `Packages` folder with every symlink resolved.
    ///
    /// The engine lists folders by their real path, so a checkout under /tmp
    /// lists as /private/tmp. A test that selects items by URL must start from
    /// that real path or nothing matches. `resolvingSymlinksInPath()` is not
    /// enough: it maps /private/tmp back to /tmp.
    static var packages: URL {
        let packages = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages")
        guard let resolved = realpath(packages.path, nil) else { return packages }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}
