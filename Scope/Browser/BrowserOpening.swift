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
                guard let source = try? pathGuard.checkTarget(url),
                    let target = try? URL(resolvingAliasFileAt: source, options: [.withoutUI, .withoutMounting]),
                    let checked = try? pathGuard.checkTarget(target),
                    let values = try? checked.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                else { return nil }
                return (checked, values.isDirectory == true && values.isPackage != true)
            }.value
            guard let (target, isFolder) = resolved else {
                showProblem("\(BuildIdentity.current.appName) can't open the target of “\(url.lastPathComponent)”.")
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
        let engine = model.engine
        Task { [weak self] in
            guard let target = await engine.readableURLs([url]).first else {
                self?.showProblem("\(BuildIdentity.current.appName) can't open \(url.path).")
                return
            }
            NSWorkspace.shared.open(target)
        }
    }

    /// Handles a path typed into the path bar or the command palette.
    func goToTypedPath(_ text: String) {
        guard let url = PathInput.resolve(text, relativeTo: model.location.folderURL, home: BuildIdentity.realHome)
        else {
            showProblem("“\(text)” isn't a path.")
            return
        }
        let engine = model.engine
        Task {
            let kind = try? await engine.item(at: url).isBrowsableFolder
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
