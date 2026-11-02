import AppKit
import ScopeEngine

/// Opening items: folders, links and files, and paths typed into the path
/// bar or the command palette. Every target passes the path guard first.
extension BrowserWindowController {
    /// Opens items: folders in this tab (extra folders in new tabs), symlinks
    /// and aliases by following them, files in their default app. Every target
    /// must pass the path guard first.
    func open(_ items: [FileItem]) {
        var openedFolderHere = false
        for item in items {
            if item.isBrowsableFolder && !item.isSymbolicLink {
                openFolder(item.url, inNewTab: openedFolderHere)
                openedFolderHere = true
            } else if item.isSymbolicLink || item.isAlias {
                followLink(item.url, inNewTab: openedFolderHere)
                openedFolderHere = true
            } else if FileEngine.isArchive(item.url), allowsWrites {
                // Scope extracts archives itself, next to the archive, like
                // Finder. Handing them to Archive Utility put them wherever its
                // settings said (often Downloads).
                startOperation(.extract(item.url))
            } else {
                openFile(item.url)
            }
        }
    }

    private func openFolder(_ url: URL, inNewTab: Bool) {
        if inNewTab, let window, let app = NSApp.delegate as? AppDelegate {
            let tab = app.makeBrowser(location: .folder(url))
            if let tabWindow = tab.window { window.addTabbedWindow(tabWindow, ordered: .above) }
        } else {
            model.navigate(to: .folder(url))
        }
    }

    private func followLink(_ url: URL, inNewTab: Bool) {
        let pathGuard = model.engine.pathGuard
        Task {
            let resolved = await Task.detached { () -> (URL, Bool)? in
                guard let target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) else {
                    return nil
                }
                let isFolder =
                    (try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
                    .map { ($0.isDirectory ?? false) && !($0.isPackage ?? false) } ?? false
                return (target, isFolder)
            }.value
            guard let (target, isFolder) = resolved else {
                showProblem("“\(url.lastPathComponent)” points to an item that doesn't exist.")
                return
            }
            guard pathGuard.permits(target) else {
                showProblem(
                    "“\(url.lastPathComponent)” points to \(target.path), outside the test disks. Scope Dev won't follow it."
                )
                return
            }
            if isFolder {
                openFolder(target, inNewTab: inNewTab)
            } else {
                openFile(target)
            }
        }
    }

    private func openFile(_ url: URL) {
        guard model.engine.pathGuard.permits(url) else {
            showProblem("\(url.path) is outside the test disks, so Scope Dev won't open it.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Handles a path typed into the path bar or the command palette.
    func goToTypedPath(_ text: String) {
        guard let url = PathInput.resolve(text, relativeTo: model.location.folderURL, home: BuildIdentity.realHome)
        else {
            showProblem("“\(text)” isn't a path.")
            return
        }
        let pathGuard = model.engine.pathGuard
        guard pathGuard.permits(url) else {
            showProblem("\(url.path) is outside the test disks, so Scope Dev won't open it.")
            return
        }
        Task {
            let kind = await Task.detached { () -> Bool? in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else {
                    return nil
                }
                return (values.isDirectory ?? false) && !(values.isPackage ?? false)
            }.value
            switch kind {
            case nil:
                showProblem("There's no folder at \(url.path).")
            case true?:
                model.navigate(to: .folder(url))
                focusFileList()
            case false?:
                // A file: show its folder with the file selected.
                model.navigate(to: .folder(url.deletingLastPathComponent()), select: url)
                focusFileList()
            }
        }
    }

    private func showProblem(_ text: String) {
        Self.logger.notice("Problem shown: \(text, privacy: .public)")
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = text
        alert.alertStyle = .informational
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
