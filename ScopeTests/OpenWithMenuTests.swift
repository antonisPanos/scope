import AppKit
import ScopeEngine
import Testing
import UniformTypeIdentifiers

@testable import Scope

@MainActor
struct OpenWithMenuTests {
    @Test func emptySpaceUsesThePaneThatOwnsTheMenu() throws {
        let controller = BrowserWindowController(location: .folder(TestPaths.packages))
        controller.toggleSplit()
        defer { controller.close() }
        let left = controller.workspace.panes[0].activeTab
        let right = controller.workspace.panes[1].activeTab
        left.model.navigate(to: .tag("Scope Open With Test"))
        controller.focusPane(0)
        let menu = try #require(right.contextMenu)

        menu.delegate?.menuNeedsUpdate?(menu)

        #expect(controller.content === right)
        #expect(menu.item(withTitle: "Open With") != nil)
        let resultsMenu = try #require(left.contextMenu)
        resultsMenu.delegate?.menuNeedsUpdate?(resultsMenu)
        #expect(resultsMenu.item(withTitle: "Open With") == nil)
        menu.delegate?.menuDidClose?(menu)
    }

    @Test func folderLookupIncludesBothKindsOfRegisteredHandlers() async {
        let folder = TestPaths.packages
        let engine = FileEngine(pathGuard: .readOnly)
        let apps = await BrowserWindowController.openWithApps(for: folder, isFolder: true, engine: engine)
        let workspace = NSWorkspace.shared
        let registered =
            workspace.urlsForApplications(toOpen: folder)
            + workspace.urlsForApplications(toOpen: .directory)
        let urls = apps.map(\.url)

        #expect(Set(urls) == Set(registered.map(\.standardizedFileURL)))
        #expect(urls.count == Set(urls).count)
        if let preferred = workspace.urlForApplication(toOpen: folder)?.standardizedFileURL, urls.contains(preferred) {
            #expect(urls.first == preferred)
        }
    }
}
