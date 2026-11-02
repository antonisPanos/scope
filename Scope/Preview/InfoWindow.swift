import AppKit
import Observation
import ScopeEngine
import SwiftUI

/// Get Info (Cmd+I or the right-click menu): everything Scope knows about one
/// item in its own small window. A folder's size is added up when the window
/// opens, never ahead of time, and the window can be closed mid-count.
/// Click any value to copy it.
@MainActor
final class InfoWindowController: NSWindowController, NSWindowDelegate {
    private let model: InfoModel
    private static var open: [InfoWindowController] = []

    static func show(for item: FileItem, engine: FileEngine, near window: NSWindow?) {
        let controller = InfoWindowController(item: item, engine: engine)
        open.append(controller)
        if let info = controller.window {
            // Centred on the screen; several at once are offset a little each.
            info.center()
            let offset = CGFloat(open.count - 1) * 22
            info.setFrameOrigin(NSPoint(x: info.frame.minX + offset, y: info.frame.minY - offset))
        }
        _ = window
        controller.showWindow(nil)
    }

    private init(item: FileItem, engine: FileEngine) {
        model = InfoModel(item: item, engine: engine)
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        window.title = "\(item.name) Info"
        window.isFloatingPanel = false
        window.becomesKeyOnlyIfNeeded = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: InfoView(model: model))
        model.load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
        Self.open.removeAll { $0 === self }
    }
}

@MainActor
@Observable
final class InfoModel {
    typealias FolderCounter = @Sendable (URL, @escaping @Sendable (FolderSize) -> Void) async throws -> FolderSize

    let item: FileItem
    let engine: FileEngine
    var details: ItemDetails?
    var folderSize: FolderSize?
    var isCounting = false
    var copied: String?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let countFolder: FolderCounter

    init(item: FileItem, engine: FileEngine, countFolder: FolderCounter? = nil) {
        self.item = item
        self.engine = engine
        self.countFolder =
            countFolder ?? { url, progress in
                try await engine.folderSize(of: url, progress: progress)
            }
    }

    func load() {
        cancel()
        let generation = generation
        let engine = engine
        let url = item.url
        tasks.append(
            Task { [weak self] in
                guard self?.generation == generation, !Task.isCancelled else { return }
                let details = try? await engine.details(for: url)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.details = details
            })
        guard item.isBrowsableFolder || item.isPackage else { return }
        isCounting = true
        let countFolder = countFolder
        tasks.append(
            Task { [weak self] in
                guard self?.generation == generation, !Task.isCancelled else { return }
                let result = try? await countFolder(url) { partial in
                    Task { @MainActor in
                        guard let self, self.generation == generation else { return }
                        self.folderSize = partial
                    }
                }
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                if let result { self.folderSize = result }
                self.isCounting = false
            })
    }

    func cancel() {
        generation += 1
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        isCounting = false
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = value
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if self?.copied == value { self?.copied = nil }
        }
    }
}

struct InfoView: View {
    let model: InfoModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(nsImage: IconCache.shared.icon(for: model.item))
                        .resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.item.name).font(.headline).textSelection(.enabled).lineLimit(2)
                        Text(model.item.kind).foregroundStyle(.secondary)
                    }
                }
                section("General", rows: generalRows)
                if !moreRows.isEmpty { section("More", rows: moreRows) }
                if !permissionRows.isEmpty { section("Permissions", rows: permissionRows) }
                Text(model.copied.map { "Copied “\($0)”" } ?? "Click a value to copy it.")
                    .font(.caption)
                    .foregroundStyle(model.copied == nil ? .tertiary : .secondary)
                    .animation(.easeOut(duration: 0.2), value: model.copied)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 300, minHeight: 360)
    }

    private func section(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                ForEach(rows, id: \.0) { label, value in
                    GridRow {
                        Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        CopyableValue(value: value, copied: model.copied == value) { model.copy(value) }
                    }
                }
            }
            .font(.callout)
        }
    }

    private var generalRows: [(String, String)] {
        let item = model.item
        var rows: [(String, String)] = []
        if item.isBrowsableFolder || item.isPackage {
            if let size = model.folderSize {
                let text = PreviewPaneController.sizeText(size.bytes)
                rows.append(("Size", model.isCounting ? "\(text) so far…" : text))
                rows.append(("On disk", PreviewPaneController.sizeText(size.allocatedBytes)))
                rows.append(("Contains", "\(size.items.formatted()) items\(model.isCounting ? " so far" : "")"))
            } else {
                rows.append(("Size", "Calculating…"))
            }
        } else if let size = item.size {
            rows.append(("Size", PreviewPaneController.sizeText(size)))
        }
        rows.append(("Where", PathBar.displayPath(item.url.deletingLastPathComponent())))
        rows.append(("Path", item.url.path))
        if let volume = model.details?.volumeName { rows.append(("Disk", volume)) }
        rows.append(("Created", DateText.format(item.created)))
        rows.append(("Modified", DateText.format(item.modified)))
        if let opened = model.details?.lastOpened { rows.append(("Last opened", DateText.format(opened))) }
        if let added = item.added { rows.append(("Added", DateText.format(added))) }
        if let tags = model.details?.tags, !tags.isEmpty { rows.append(("Tags", tags.joined(separator: ", "))) }
        return rows
    }

    private var moreRows: [(String, String)] {
        guard let details = model.details else { return [] }
        var rows: [(String, String)] = []
        if let width = details.pixelWidth, let height = details.pixelHeight {
            rows.append(("Dimensions", "\(width) × \(height)"))
        }
        if let camera = details.cameraModel { rows.append(("Camera", camera)) }
        if let taken = details.dateTaken { rows.append(("Taken", taken)) }
        if let duration = details.duration {
            rows.append(("Duration", Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))))
        }
        if let target = details.linkTarget { rows.append(("Points to", target)) }
        if model.item.isHidden { rows.append(("Hidden", "Yes")) }
        return rows
    }

    private var permissionRows: [(String, String)] {
        guard let details = model.details else { return [] }
        var rows: [(String, String)] = []
        if let owner = details.owner { rows.append(("Owner", owner)) }
        if let group = details.group { rows.append(("Group", group)) }
        if let permissions = details.permissions { rows.append(("Mode", permissions)) }
        if details.isLocked { rows.append(("Locked", "Yes")) }
        return rows
    }
}

/// A value that copies itself when clicked, with a brief "copied" flash.
struct CopyableValue: View {
    let value: String
    let copied: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(value)
            .lineLimit(3)
            .truncationMode(.middle)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(copied ? Color.accentColor.opacity(0.25) : hovering ? Color.secondary.opacity(0.12) : .clear)
            )
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help("Click to copy")
            .animation(.easeOut(duration: 0.15), value: copied)
    }
}
