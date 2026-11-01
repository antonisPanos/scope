import AppKit
import Observation
import os
import PandoraEngine

/// The app's side of the operation queue: starts operations, asks about
/// conflicts, and keeps a snapshot of every operation for the activity panels,
/// the toolbar ring and the Dock icon. It reads snapshots about ten times a
/// second while something runs and not at all when idle.
@MainActor
@Observable
final class OperationsController {
    static let shared = OperationsController()

    private(set) var snapshots: [OperationCenter.Snapshot] = []

    @ObservationIgnored let center: OperationCenter
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let dockProgress = DockProgress()
    private static let logger = Logger(subsystem: "com.antonispanos.pandora", category: "Operations")

    private init() {
        let engine = BuildIdentity.current.makeEngine()
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
        do {
            let id = try await center.enqueue(operation)
            Self.logger.notice("Queued: \(operation.title, privacy: .public)")
            refresh()
            return id
        } catch {
            Self.logger.notice("Refused: \(operation.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
            try await center.undo(id)
            refresh()
        } catch {
            Self.showAlert("Can't undo.", error.localizedDescription, on: window)
        }
    }

    var canUndo: Bool {
        snapshots.contains(where: \.canUndo)
    }

    func cancel(_ id: UUID) { Task { await center.cancel(id); refresh() } }
    func pause(_ id: UUID) { Task { await center.pause(id); refresh() } }
    func resume(_ id: UUID) { Task { await center.resume(id); refresh() } }
    func startNow(_ id: UUID) { Task { await center.startNow(id); refresh() } }
    func move(_ id: UUID, by offset: Int) { Task { await center.move(id, by: offset); refresh() } }
    func clearFinished() { Task { await center.clearFinished(); refresh() } }

    // MARK: - Snapshots

    func refresh() {
        Task {
            snapshots = await center.snapshots()
            dockProgress.show(overallFraction)
            if active.isEmpty {
                pollTask?.cancel()
                pollTask = nil
            } else if pollTask == nil {
                // The controller lives as long as the app, so the loop can hold it.
                pollTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(100))
                        self.snapshots = await self.center.snapshots()
                        self.dockProgress.show(self.overallFraction)
                        if self.active.isEmpty { self.pollTask = nil; return }
                    }
                }
            }
        }
    }

    // MARK: - Conflicts

    /// Asks on the frontmost browser window what to do about an existing item.
    private static func ask(_ conflict: Conflict) async -> (choice: ConflictChoice, applyToAll: Bool) {
        let alert = NSAlert()
        alert.messageText = "An item named “\(conflict.existing.lastPathComponent)” already exists in “\(conflict.existing.deletingLastPathComponent().lastPathComponent)”."
        alert.informativeText = "Replacing moves the existing item to the Trash, so you can get it back."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Stop")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to all"
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
