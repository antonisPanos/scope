import AppKit
import Observation
import os
import PandoraEngine

struct SidebarItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable { case recents, folder, favorite, volume, diskImage, tag }

    let id: String
    let kind: Kind
    let title: String
    let symbolName: String
    let location: Location
    /// False for places the path guard refuses (everything outside the test
    /// disks in development builds). They stay visible but can't be opened.
    let isEnabled: Bool
    var subtitle: String?
    var volumeURL: URL?
    var canEject = false
    var tagName: String?
}

/// What the sidebar lists, shared by every window: favourites, volumes, disk
/// images and tags. Built in the background (volume and permission checks
/// touch the disk) and refreshed when disks mount or unmount.
@MainActor
@Observable
final class SidebarStore {
    static let shared = SidebarStore()

    private(set) var favorites: [SidebarItem] = []
    private(set) var locations: [SidebarItem] = []
    private(set) var diskImages: [SidebarItem] = []
    private(set) var tags: [SidebarItem] = []
    private(set) var ejecting: Set<String> = []

    @ObservationIgnored private let tagCatalog = TagCatalog()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    private static let logger = Logger(subsystem: "com.antonispanos.pandora", category: "Sidebar")

    var allItems: [SidebarItem] { favorites + locations + diskImages + tags }

    func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        tagCatalog.onChange = { [weak self] in self?.rebuildTags() }
        tagCatalog.start()
        rebuildTags()
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        let favoritePaths = AppSettings.shared.favoritePaths
        let pathGuard = BuildIdentity.current.pathGuard
        let home = BuildIdentity.realHome
        refreshTask = Task {
            let built = await Task.detached(priority: .userInitiated) {
                Self.build(favoritePaths: favoritePaths, pathGuard: pathGuard, home: home)
            }.value
            guard !Task.isCancelled else { return }
            favorites = built.favorites
            locations = built.locations
            diskImages = built.diskImages
        }
    }

    func item(for location: Location) -> SidebarItem? {
        allItems.first { $0.location == location && $0.kind != .volume && $0.kind != .diskImage }
            ?? allItems.first { $0.location == location }
    }

    // MARK: - Favorites

    func addFavorite(_ url: URL) {
        var paths = AppSettings.shared.favoritePaths
        guard !paths.contains(url.path) else { return }
        paths.append(url.path)
        AppSettings.shared.favoritePaths = paths
    }

    func removeFavorite(_ item: SidebarItem) {
        guard item.kind == .favorite, let url = item.location.folderURL else { return }
        AppSettings.shared.favoritePaths.removeAll { $0 == url.path }
    }

    // MARK: - Eject

    func eject(_ item: SidebarItem, presentingIn window: NSWindow?) {
        guard let url = item.volumeURL, !ejecting.contains(item.id) else { return }
        ejecting.insert(item.id)
        let pathGuard = BuildIdentity.current.pathGuard
        Task {
            do {
                try await Volumes.eject(url, pathGuard: pathGuard)
            } catch {
                Self.logger.error("Eject of \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                let alert = NSAlert()
                alert.messageText = "\(item.title) couldn't be ejected."
                let blocker = Volumes.blockingApp(from: error)
                if let blocker {
                    // Name the app holding files open, and offer to eject anyway.
                    alert.informativeText = "\(blocker) is using files on it. Quit \(blocker) or close those files, or force eject (unsaved changes in \(blocker) may be lost)."
                    alert.addButton(withTitle: "Cancel")
                    alert.addButton(withTitle: "Force Eject")
                } else {
                    alert.informativeText = Self.describeEjectError(error)
                }
                let choice: NSApplication.ModalResponse
                if let window { choice = await alert.beginSheetModal(for: window) } else { choice = alert.runModal() }
                if blocker != nil, choice == .alertSecondButtonReturn {
                    do {
                        try await Volumes.forceEject(url, pathGuard: pathGuard)
                    } catch {
                        let failed = NSAlert()
                        failed.messageText = "\(item.title) couldn't be ejected."
                        failed.informativeText = error.localizedDescription
                        if let window { failed.beginSheetModal(for: window, completionHandler: nil) } else { failed.runModal() }
                    }
                }
            }
            ejecting.remove(item.id)
            refresh()
        }
    }

    private static func describeEjectError(_ error: Error) -> String {
        if error is PathGuardViolation, BuildIdentity.current.isDevelopment {
            return "Pandora Dev can only eject the test disks."
        }
        let nsError = error as NSError
        if nsError.code == NSFileWriteVolumeReadOnlyError || nsError.domain == NSCocoaErrorDomain {
            return "An app may still be using files on it. Close them and try again. (\(error.localizedDescription))"
        }
        return error.localizedDescription
    }

    // MARK: - Building

    private func rebuildTags() {
        tags = tagCatalog.tags.map { tag in
            SidebarItem(id: "tag:" + tag, kind: .tag, title: tag, symbolName: "circle.fill",
                        location: .tag(tag), isEnabled: true, tagName: tag)
        }
    }

    private struct Built: Sendable {
        var favorites: [SidebarItem] = []
        var locations: [SidebarItem] = []
        var diskImages: [SidebarItem] = []
    }

    nonisolated private static func build(favoritePaths: [String], pathGuard: PathGuard, home: URL) -> Built {
        var built = Built()
        built.favorites.append(SidebarItem(id: "recents", kind: .recents, title: "Recents", symbolName: "clock",
                                           location: .recents, isEnabled: true))
        let standard: [(String, String, URL)] = [
            ("Applications", "app.dashed", URL(fileURLWithPath: "/Applications")),
            ("Desktop", "menubar.dock.rectangle", home.appendingPathComponent("Desktop")),
            ("Documents", "doc", home.appendingPathComponent("Documents")),
            ("Downloads", "arrow.down.circle", home.appendingPathComponent("Downloads")),
            (home.lastPathComponent, "house", home),
        ]
        for (title, symbol, url) in standard {
            built.favorites.append(SidebarItem(id: "std:" + url.path, kind: .folder, title: title, symbolName: symbol,
                                               location: .folder(url), isEnabled: pathGuard.permits(url)))
        }
        for path in favoritePaths {
            let url = URL(fileURLWithPath: path)
            built.favorites.append(SidebarItem(id: "fav:" + path, kind: .favorite, title: url.lastPathComponent,
                                               symbolName: "folder", location: .folder(url),
                                               isEnabled: pathGuard.permits(url)))
        }

        for volume in Volumes.mounted() {
            var item = SidebarItem(
                id: "vol:" + volume.url.path,
                kind: volume.isDiskImage ? .diskImage : .volume,
                title: volume.name,
                symbolName: volume.isDiskImage ? "opticaldiscdrive" : volume.isInternal ? "internaldrive" : "externaldrive",
                location: .folder(volume.url),
                isEnabled: pathGuard.permits(volume.url))
            item.volumeURL = volume.url
            item.canEject = volume.isEjectable
            if let image = volume.imagePath {
                item.subtitle = (image as NSString).lastPathComponent
                built.diskImages.append(item)
            } else {
                built.locations.append(item)
            }
        }
        return built
    }
}
