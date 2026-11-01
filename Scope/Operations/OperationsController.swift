import AppKit
import Observation
import ScopeEngine
import os

/// The app's side of the operation queue: starts operations, asks about
/// conflicts, and keeps a snapshot of every operation for the activity panels,
/// the toolbar ring and the Dock icon. It reads snapshots about ten times a
/// second while something runs and not at all when idle.
@MainActor
@Observable
final class OperationsController {
    static let shared = OperationsController()

    private(set) var snapshots: [OperationCenter.Snapshot] = []
    /// Operations started since the activity drawer was last opened.
    private(set) var unreadIDs: Set<UUID> = []

    var unreadCount: Int { unreadIDs.count }
    /// Whether an activity drawer is open; operations started then count as seen.
    @ObservationIgnored var drawerVisible = false

    /// Called when a window opens its activity drawer.
    func markAllRead() {
        unreadIDs = []
        SystemNotifier.shared.clearDelivered()
    }

    /// Set when the user chose "Quit When Done": Scope quits once the queue empties.
    @ObservationIgnored var quitWhenIdle = false

    /// What the footer shows: the operation running now, or the one that
    /// finished last if that was in the last few seconds.
    var footerSnapshot: OperationCenter.Snapshot? {
        if let running = snapshots.first(where: {
            $0.state == .running || $0.state == .paused || $0.state == .cancelling
        }) {
            return running
        }
        let recent = snapshots.filter { $0.finished.map { Date().timeIntervalSince($0) < 4 } ?? false }
        return recent.max { ($0.finished ?? .distantPast) < ($1.finished ?? .distantPast) }
    }

    @ObservationIgnored let center: OperationCenter
    @ObservationIgnored private let engine: FileEngine
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let dockProgress = DockProgress()
    @ObservationIgnored private let keepAlive = KeepAlive()
    private static let logger = Logger(subsystem: "com.antonispanos.scope", category: "Operations")

    private init() {
        let engine = BuildIdentity.current.makeEngine()
        self.engine = engine
        center = OperationCenter(engine: engine) { conflict in
            await OperationsController.ask(conflict)
        }
        Task {
            _ = await center.observe { Task { @MainActor in OperationsController.shared.refresh() } }
        }
    }

    var active: [OperationCenter.Snapshot] { snapshots.filter(\.isActive) }

    /// Overall progress of running operations, for the toolbar ring and the Dock.
    var overallFraction: Double? {
        let running = active.filter { $0.state == .running || $0.state == .paused || $0.state == .cancelling }
        guard !running.isEmpty else { return nil }
        let total = running.reduce(Int64(0)) { $0 + $1.progress.bytesTotal }
        if total > 0 { return Double(running.reduce(Int64(0)) { $0 + $1.progress.bytesDone }) / Double(total) }
        return running.compactMap(\.progress.fraction).min()
    }

    // MARK: - Starting

    /// Queues an operation; shows an alert on `window` when it's refused.
    @discardableResult
    func start(_ kind: FileOperation.Kind, from window: NSWindow?) async -> UUID? {
        let operation = FileOperation(kind)
        // An archive whose unpacked size is known and too big is refused before
        // anything is written; for the others, the extraction stops by itself.
        if case .extract(let archive) = kind {
            let engine = engine
            if let problem = await Task.detached(operation: { await engine.extractionSpaceProblem(archive) }).value {
                Self.showAlert("Not enough space to extract.", problem, on: window)
                return nil
            }
        }
        do {
            let id = try await center.enqueue(operation)
            if !drawerVisible { unreadIDs.insert(id) }
            SystemNotifier.shared.requestPermissionIfNeeded()
            Self.logger.notice("Queued: \(operation.title, privacy: .public)")
            refresh()
            return id
        } catch {
            Self.logger.notice(
                "Refused: \(operation.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            Self.showAlert("Can't do that right now.", error.localizedDescription, on: window)
            return nil
        }
    }

    func undoLast(from window: NSWindow?) async {
        guard let id = await center.lastUndoable() else {
            NSSound.beep()
            return
        }
        await undo(id, from: window)
    }

    func undo(_ id: UUID, from window: NSWindow?) async {
        do {
            if let undoID = try await center.undo(id) { unreadIDs.insert(undoID) }
            refresh()
        } catch {
            Self.showAlert("Can't undo.", error.localizedDescription, on: window)
        }
    }

    var canUndo: Bool {
        snapshots.contains(where: \.canUndo)
    }

    func cancel(_ id: UUID) {
        Task {
            await center.cancel(id)
            refresh()
        }
    }
    func pause(_ id: UUID) {
        Task {
            await center.pause(id)
            refresh()
        }
    }
    func resume(_ id: UUID) {
        Task {
            await center.resume(id)
            refresh()
        }
    }
    func startNow(_ id: UUID) {
        Task {
            await center.startNow(id)
            refresh()
        }
    }
    func move(_ id: UUID, by offset: Int) {
        Task {
            await center.move(id, by: offset)
            refresh()
        }
    }
    func clearFinished() {
        Task {
            await center.clearFinished()
            refresh()
        }
    }

    /// Cancels everything queued or running, for "Quit Now".
    func cancelAll() {
        let ids = active.map(\.id)
        Task {
            for id in ids { await center.cancel(id) }
            refresh()
        }
    }

    // MARK: - Snapshots

    func refresh() {
        Task {
            apply(await center.snapshots())
            if active.isEmpty {
                pollTask?.cancel()
                pollTask = nil
            } else if pollTask == nil {
                // The controller lives as long as the app, so the loop can hold it.
                pollTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(100))
                        self.apply(await self.center.snapshots())
                        if self.active.isEmpty {
                            self.pollTask = nil
                            return
                        }
                    }
                }
            }
        }
    }

    /// Everything that follows the queue: the Dock bar, staying awake,
    /// system notifications, and a quit the user asked to wait for.
    private func apply(_ new: [OperationCenter.Snapshot]) {
        snapshots = new
        dockProgress.show(overallFraction)
        keepAlive.update(busy: !active.isEmpty)
        SystemNotifier.shared.track(new, drawerVisible: drawerVisible)
        if quitWhenIdle, active.isEmpty {
            quitWhenIdle = false
            Self.logger.notice("Queue empty; quitting as asked")
            NSApp.terminate(nil)
        }
    }

    // MARK: - Conflicts

    /// Asks on the frontmost browser window what to do about an existing item.
    private static func ask(_ conflict: Conflict) async -> (choice: ConflictChoice, applyToAll: Bool) {
        let alert = NSAlert()
        alert.messageText =
            "An item named “\(conflict.existing.lastPathComponent)” already exists in “\(conflict.existing.deletingLastPathComponent().lastPathComponent)”."
        alert.informativeText = "Replacing moves the existing item to the Trash, so you can get it back."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Stop")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to all"
        SystemNotifier.shared.conflictWaiting(name: conflict.existing.lastPathComponent)
        defer { SystemNotifier.shared.conflictAnswered() }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let response: NSApplication.ModalResponse
        if let window, window.attachedSheet == nil {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        let all = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return (.keepBoth, all)
        case .alertSecondButtonReturn: return (.replace, all)
        case .alertThirdButtonReturn: return (.skip, all)
        default: return (.stop, false)
        }
    }

    static func showAlert(_ title: String, _ text: String, on window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

/// A progress bar on the Dock icon while operations run.
@MainActor
private final class DockProgress {
    private var bar: NSProgressIndicator?

    func show(_ fraction: Double?) {
        let tile = NSApp.dockTile
        guard let fraction else {
            if bar != nil {
                tile.contentView = nil
                bar = nil
                tile.display()
            }
            return
        }
        if bar == nil {
            let view = NSImageView(image: NSApp.applicationIconImage)
            let progress = NSProgressIndicator(frame: NSRect(x: 10, y: 8, width: tile.size.width - 20, height: 14))
            progress.style = .bar
            progress.isIndeterminate = false
            progress.minValue = 0
            progress.maxValue = 1
            view.addSubview(progress)
            tile.contentView = view
            bar = progress
        }
        bar?.doubleValue = fraction
        tile.display()
    }
}
