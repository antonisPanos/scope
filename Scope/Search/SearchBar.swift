import ScopeEngine
import SwiftUI

/// The filter bar under the path bar while a search is on screen.
struct SearchBar: View {
    @Bindable var settings: SearchSettings
    let tags: [String]
    var resultCount: Int
    var isSearching: Bool
    var onChange: () -> Void
    var onStop: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $settings.mode) {
                ForEach(SearchSettings.Mode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()

            if settings.mode != .contents {
                Menu(optionsTitle) {
                    Toggle("Include Subfolders", isOn: $settings.includeSubfolders)
                    Toggle("Include Hidden Files", isOn: $settings.includeHidden)
                    Toggle("Look Inside Packages", isOn: $settings.includePackages)
                }
                .fixedSize()
                Menu(kindTitle) {
                    ForEach(SearchQuery.Kind.allCases, id: \.self) { kind in
                        Toggle(
                            kind.rawValue.capitalized,
                            isOn: Binding(
                                get: { settings.kinds.contains(kind) },
                                set: { on in if on { settings.kinds.insert(kind) } else { settings.kinds.remove(kind) }
                                }))
                    }
                    Divider()
                    Button("Any kind") { settings.kinds = [] }
                }
                .fixedSize()
                Picker("", selection: $settings.size) {
                    ForEach(SearchSettings.SizeFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("", selection: $settings.modified) {
                    ForEach(SearchSettings.DateFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("", selection: $settings.tag) {
                    Text("Any tag").tag(String?.none)
                    ForEach(tags, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer(minLength: 8)
            if isSearching {
                ProgressView().controlSize(.small)
                Text("\(resultCount.formatted()) found").foregroundStyle(.secondary).monospacedDigit().fixedSize()
                Button("Stop", action: onStop)
            } else {
                Text("\(resultCount.formatted()) found").foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("End search (Esc)")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .onChange(of: settings.mode) { onChange() }
        .onChange(of: settings.includeSubfolders) { onChange() }
        .onChange(of: settings.includeHidden) { onChange() }
        .onChange(of: settings.includePackages) { onChange() }
        .onChange(of: settings.kinds) { onChange() }
        .onChange(of: settings.size) { onChange() }
        .onChange(of: settings.modified) { onChange() }
        .onChange(of: settings.tag) { onChange() }
    }

    /// "Subfolders", or what differs from the defaults.
    private var optionsTitle: String {
        var parts: [String] = [settings.includeSubfolders ? "Subfolders" : "This folder only"]
        if settings.includeHidden { parts.append("hidden") }
        if settings.includePackages { parts.append("packages") }
        return parts.joined(separator: ", ")
    }

    private var kindTitle: String {
        settings.kinds.isEmpty
            ? "Any kind" : settings.kinds.map(\.rawValue.capitalized).sorted().joined(separator: ", ")
    }
}
