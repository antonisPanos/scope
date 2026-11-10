import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

@Suite(.serialized) struct VerifiedSourceTests {
    @Test(arguments: ["replacement", "edit", "added-child", "edited-child"])
    func changedSourceIsKeptAfterPublication(_ change: String) throws {
        let sandbox = try Sandbox()
        let directory = change.contains("child")
        let source = directory ? sandbox.url("source") : sandbox.url("source.txt")
        let destination = directory ? sandbox.url("copy") : sandbox.url("copy.txt")
        if directory {
            try sandbox.write("source/child.txt", "original")
            try sandbox.write("copy/child.txt", "original")
        } else {
            try sandbox.write("source.txt", "original")
            try sandbox.write("copy.txt", "original")
        }
        let engine = sandbox.engine
        let evidence = try engine.verifyCopy(source, destination, control: nil)
        let changes = Recorded<FolderItemsChanged>()
        let errors = Recorded<String>()
        let old = sandbox.url("old.txt")
        let newChild = sandbox.url("source/new.txt")
        let child = sandbox.url("source/child.txt")
        let undo = UndoRecorder { announcement in
            changes.append(announcement)
            do {
                switch change {
                case "replacement":
                    try FileManager.default.moveItem(at: source, to: old)
                    try Data("new replacement".utf8).write(to: source)
                case "edit": try Data("new content".utf8).write(to: source)
                case "added-child": try Data("new".utf8).write(to: newChild)
                default: try Data("new content".utf8).write(to: child)
                }
            } catch { errors.append(error.localizedDescription) }
        }
        undo.add(.trashCreated(destination, fileID: FileEngine.fileID(destination)))
        #expect(errors.all.isEmpty)
        #expect(throws: OperationError.copiedSourceChanged(source.path)) {
            try engine.retireVerifiedSource(source, evidence: evidence)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.trash.path).isEmpty)
        #expect(undo.recorded.count == 1)
        #expect(changes.all.count == 1)
        #expect(changes.all.first?.added == [destination.lastPathComponent])
        #expect(changes.all.first?.removed.isEmpty == true)
        let kept = directory ? (change == "added-child" ? "source/new.txt" : "source/child.txt") : "source.txt"
        #expect(try String(contentsOf: sandbox.url(kept), encoding: .utf8).hasPrefix("new"))
    }

    @Test func anEarlierChildChangedDuringLaterVerificationIsKept() throws {
        let sandbox = try Sandbox()
        for root in ["source", "copy"] {
            try sandbox.write("\(root)/a.txt", "first")
            try sandbox.write("\(root)/b.txt", "second")
        }
        var engine = sandbox.engine
        let source = sandbox.url("source")
        let first = sandbox.url("source/a.txt")
        let errors = Recorded<String>()
        engine.verifiedItemHook = { path in
            guard path.hasSuffix("/b.txt") else { return }
            do { try Data("changed first".utf8).write(to: first) } catch { errors.append(error.localizedDescription) }
        }
        let evidence = try engine.verifyCopy(source, sandbox.url("copy"), control: nil)
        #expect(errors.all.isEmpty)
        #expect(throws: OperationError.copiedSourceChanged(source.path)) {
            try engine.retireVerifiedSource(source, evidence: evidence)
        }
        #expect(try String(contentsOf: first, encoding: .utf8) == "changed first")
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.trash.path).isEmpty)
    }

    @Test func unchangedVerifiedSourceCanBeRetiredToPrivateTrash() throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("source.txt", "original")
        let copy = try sandbox.write("copy.txt", "original")
        let evidence = try sandbox.engine.verifyCopy(source, copy, control: nil)
        let trashed = try #require(try sandbox.engine.retireVerifiedSource(source, evidence: evidence))
        #expect(!sandbox.exists("source.txt"))
        #expect(trashed.deletingLastPathComponent() == sandbox.trash)
        #expect(try String(contentsOf: trashed, encoding: .utf8) == "original")
    }
}
