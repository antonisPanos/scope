import AppKit
import SwiftUI

/// Pandora's colours, from the asset catalog, each with a light and a dark
/// variant. The accent (Pandora teal) is the asset catalog's AccentColor, so
/// controls pick it up through NSColor.controlAccentColor.
@MainActor
enum Palette {
    static let windowBackground = named("WindowBackground")
    static let sidebarBackground = named("SidebarBackground")
    static let panelBackground = named("PanelBackground")
    static let primaryText = named("PrimaryText")
    static let secondaryText = named("SecondaryText")
    static let separator = named("Separator")
    static let selection = named("Selection")
    static let warning = named("Warning")
    static let error = named("Error")
    static var accent: NSColor { .controlAccentColor }

    /// Folder and tag colours, matching Finder's tag colours by name.
    static func tagColor(_ tag: String) -> NSColor? {
        switch tag.lowercased() {
        case "red": named("FolderRed")
        case "orange": named("FolderOrange")
        case "yellow": named("FolderYellow")
        case "green": named("FolderGreen")
        case "blue": named("FolderBlue")
        case "purple": named("FolderPurple")
        case "gray", "grey": named("FolderGraphite")
        default: nil
        }
    }

    private static func named(_ name: String) -> NSColor {
        NSColor(named: name) ?? .labelColor
    }
}

extension Color {
    @MainActor static func palette(_ color: NSColor) -> Color { Color(nsColor: color) }
}
