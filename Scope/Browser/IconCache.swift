import AppKit
import ScopeEngine
import UniformTypeIdentifiers

/// Icons by type, cached, so scrolling never asks the disk for an icon.
/// Apps and other packages get their own icon, loaded once in the background.
@MainActor
final class IconCache {
    static let shared = IconCache()

    private var byType: [String: NSImage] = [:]
    private var byPath: [String: NSImage] = [:]
    private var loading: Set<String> = []

    func icon(for item: FileItem) -> NSImage {
        if item.isPackage || item.isFolderLink {
            if let icon = byPath[item.url.path] { return icon }
            // A link to a folder shows the folder's own icon (Google Drive's
            // has one); the row adds the link arrow.
            loadIcon(for: item.url.path)
        }
        let key: String
        let type: UTType
        if item.isBrowsableFolder || item.isFolderLink {
            key = "public.folder"
            type = .folder
        } else if item.isSymbolicLink {
            key = "symlink:" + item.url.pathExtension.lowercased()
            type = UTType(filenameExtension: item.url.pathExtension) ?? .data
        } else {
            key = (item.isPackage ? "package:" : "") + item.url.pathExtension.lowercased()
            type =
                UTType(filenameExtension: item.url.pathExtension, conformingTo: item.isPackage ? .package : .data)
                ?? .data
        }
        if let icon = byType[key] { return icon }
        let icon = NSWorkspace.shared.icon(for: type)
        byType[key] = icon
        return icon
    }

    /// Loads a path-specific icon only after the target passes the active
    /// read guard. Resolving folder links can otherwise reach outside it.
    private func loadIcon(for path: String) {
        guard !loading.contains(path) else { return }
        loading.insert(path)
        let pathGuard = BuildIdentity.current.pathGuard
        Task {
            let icon = await Task.detached(priority: .utility) { () -> LoadedIcon? in
                guard let checked = try? pathGuard.checkTarget(URL(fileURLWithPath: path)) else { return nil }
                return LoadedIcon(image: NSWorkspace.shared.icon(forFile: checked.path))
            }.value
            if let icon { byPath[path] = icon.image }
            loading.remove(path)
            if icon != nil { NotificationCenter.default.post(name: Self.didLoad, object: path) }
        }
    }

    static let didLoad = Notification.Name("ScopeIconDidLoad")
}

/// Carries an icon from the background task that loaded it. The image is not
/// touched again off the main thread.
private struct LoadedIcon: @unchecked Sendable {
    let image: NSImage
}
