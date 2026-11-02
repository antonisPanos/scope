import Observation
import SwiftUI

/// Which sidebar row a window has selected, and what to do when the user picks one.
@MainActor
@Observable
final class SidebarSelection {
    var selectedID: String?
    @ObservationIgnored var onSelect: ((SidebarItem) -> Void)?
    @ObservationIgnored var onEject: ((SidebarItem) -> Void)?
    @ObservationIgnored var onOpenInSplit: ((SidebarItem) -> Void)?
    @ObservationIgnored var onOpenInNewTab: ((SidebarItem) -> Void)?
}

/// The sidebar: Favorites (Recents, standard folders, your own), Locations,
/// Disk Images with the file each came from, and Tags. Places the path guard
/// refuses show dimmed.
struct SidebarView: View {
    let store: SidebarStore
    @Bindable var selection: SidebarSelection

    var body: some View {
        // No List selection: the system draws a selected sidebar row in the
        // accent colour while the sidebar has focus, and the teal icons vanish
        // on it. Scope draws its own quiet grey highlight instead, the same
        // whether the row was just clicked or the window is showing that place.
        List {
            Section("Favorites") {
                ForEach(store.favorites) { row($0) }
            }
            if !store.locations.isEmpty {
                Section("Locations") {
                    ForEach(store.locations) { row($0) }
                }
            }
            if !store.diskImages.isEmpty {
                Section("Disk Images") {
                    ForEach(store.diskImages) { row($0) }
                }
            }
            Section("Tags") {
                ForEach(store.tags) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 150, maxWidth: .infinity)
    }

    @ViewBuilder
    private func row(_ item: SidebarItem) -> some View {
        HStack(spacing: 6) {
            icon(item)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if item.canEject {
                if store.ejecting.contains(item.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        selection.onEject?(item)
                    } label: {
                        Image(systemName: "eject.fill").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Eject \(item.title)")
                    .disabled(!item.isEnabled)
                }
            }
        }
        .opacity(item.isEnabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .onTapGesture { pick(item) }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(selection.selectedID == item.id ? 0.1 : 0))
                .padding(.horizontal, 10)
        )
        .accessibilityAddTraits(selection.selectedID == item.id ? [.isButton, .isSelected] : .isButton)
        .help(
            item.isEnabled
                ? (item.location.folderURL?.path ?? item.title)
                : "\(BuildIdentity.current.appName) can't open this place"
        )
        .contextMenu {
            if item.isEnabled {
                Button("Open in New Tab") { selection.onOpenInNewTab?(item) }
                Button("Open in Split View") { selection.onOpenInSplit?(item) }
            }
            if item.kind == .favorite {
                Button("Remove from Sidebar") { store.removeFavorite(item) }
            }
            if item.canEject {
                Button("Eject \(item.title)") { selection.onEject?(item) }.disabled(!item.isEnabled)
            }
        }
    }

    private func pick(_ item: SidebarItem) {
        guard item.isEnabled else { return }
        selection.selectedID = item.id
        selection.onSelect?(item)
    }

    @ViewBuilder
    private func icon(_ item: SidebarItem) -> some View {
        if let tag = item.tagName {
            Image(systemName: "circle.fill")
                .foregroundStyle(Palette.tagColor(tag).map { Color(nsColor: $0) } ?? .secondary)
                .font(.system(size: 9))
                .frame(width: 18)
        } else {
            Image(systemName: item.symbolName)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
        }
    }
}
