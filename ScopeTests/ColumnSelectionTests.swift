import Foundation
import ScopeEngine
import Testing

@testable import Scope

@MainActor struct ColumnSelectionTests {
    @Test func aReloadKeepsASelectionInADeeperColumn() async throws {
        let root = TestPaths.packages
        let model = BrowserModel(engine: FileEngine(pathGuard: .readOnly), location: .folder(root))
        let controller = ColumnViewController(model: model)
        defer {
            controller.close()
            model.close()
        }
        _ = controller.view
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        model.onChange = { [weak controller] in controller?.modelDidChange($0) }
        let folder = root.appendingPathComponent("ScopeEngine")
        let leaf = folder.appendingPathComponent("Package.swift")
        for _ in 0..<500 {
            if model.state == .loaded, controller.select([folder], scroll: false) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<500 {
            if controller.select([leaf], scroll: false) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.selectedItems.map(\.url.path) == [leaf.path])
        controller.modelDidChange(.items)
        #expect(controller.selectedItems.map(\.url.path) == [leaf.path])
    }
}
