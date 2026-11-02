import AppKit
import Testing

@testable import Scope

/// The one command list behind the menus, the right-click menu and the
/// command palette.
@MainActor
struct CommandsTests {
    @Test func idsAreUnique() {
        let ids = Commands.all.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate ids: \(ids.filter { id in ids.filter { $0 == id }.count > 1 })")
    }

    @Test func shortcutsAreUnique() {
        var seen: [String: String] = [:]
        for command in Commands.all where !command.key.isEmpty {
            let shortcut = command.shortcutText
            #expect(seen[shortcut] == nil, "\(shortcut) is used by both \(seen[shortcut] ?? "") and \(command.id)")
            seen[shortcut] = command.id
        }
    }

    /// AppKit's own Edit and window items own these; a command reusing one
    /// would shadow Copy, Paste, Undo, Quit and the like.
    @Test func shortcutsLeaveTheStandardOnesAlone() {
        let reserved: Set<String> = ["a", "c", "v", "x", "z", "q", "w", "h", "m", ","]
        for command in Commands.all where command.modifiers == .command {
            #expect(!reserved.contains(command.key), "\(command.id) takes ⌘\(command.key.uppercased())")
        }
    }

    @Test func everyCommandHasATitle() {
        for command in Commands.all {
            #expect(!command.title.trimmingCharacters(in: .whitespaces).isEmpty, "\(command.id) has no title")
        }
    }

    /// The right-click menu looks commands up by id; a renamed command would
    /// silently drop out of it.
    @Test func theContextMenuFindsItsCommands() {
        let ids = [
            "newFolder", "paste", "moveHere", "getInfo", "copyPath", "addToSidebar", "toggleHidden", "open",
            "openInNewTab", "openInSplit", "quickLook", "print", "rename", "duplicate", "compress", "extract",
            "mount", "mountReadOnly", "eject", "trash", "cut", "copy", "sort.name", "sort.kind", "sort.added",
            "sort.modified", "sort.created", "sort.size", "sort.ascending", "sort.descending",
        ]
        for id in ids {
            #expect(Commands.command(id: id) != nil, "no command \(id)")
        }
        for mode in ViewMode.allCases {
            #expect(Commands.command(id: "view." + mode.rawValue) != nil)
        }
    }
}
