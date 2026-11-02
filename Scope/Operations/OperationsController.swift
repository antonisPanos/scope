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
    /// Each operation's state at the last refresh, to notice the ones that just failed.
    @ObservationIgnored private var lastStates: [UUID: OperationCenter.State] = [:]
    private static let logger = Logger(subsystem: "com.antonispanos.scope", category: "Operations")

    private init() {
        let engine = BuildIdentity.current.makeEngine()
        self.engine = engine
        center = OperationCenter(
            engine: engine,
            resolveConflict: { conflict in await OperationsController.ask(conflict) },
            confirmPermanentDeletion: { request in await OperationsController.confirm(request) },
            resolveFailure: { failure in await OperationsController.ask(failure) })
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
        // Files edited since the operation made them are trashed only after a yes.
        let changed = await center.changedSinceMade(id)
        if !changed.isEmpty {
            guard await Self.confirmUndo(changing: changed, on: window) else { return }
        }
        do {
            if let undoID = try await center.undo(id, includingChanged: !changed.isEmpty) {
                unreadIDs.insert(undoID)
            }
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
        let failures = Self.newlyFailed(new.map { ($0.id, $0.title, $0.state) }, previous: lastStates)
        lastStates = Dictionary(new.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        snapshots = new
        for failure in failures {
            Self.logger.error("Failed: \(failure.title, privacy: .public): \(failure.message, privacy: .public)")
            // In the background, a system notification says it; with the
            // activity drawer open, the drawer does. Otherwise a quick failure
            // would only flash in the footer.
            if NSApp.isActive, !drawerVisible {
                Self.showAlert("\(failure.title) didn't finish.", failure.message, on: NSApp.keyWindow)
            }
        }
        dockProgress.show(overallFraction)
        keepAlive.update(busy: !active.isEmpty)
        SystemNotifier.shared.track(new, drawerVisible: drawerVisible)
        if quitWhenIdle, active.isEmpty {
            quitWhenIdle = false
            Self.logger.notice("Queue empty; quitting as asked")
            NSApp.terminate(nil)
        }
    }

    /// Operations that have failed since the last refresh, with their error:
    /// ones that were waiting or running then, and ones too quick to be seen.
    nonisolated static func newlyFailed(
        _ current: [(id: UUID, title: String, state: OperationCenter.State)], previous: [UUID: OperationCenter.State]
    ) -> [(title: String, message: String)] {
        current.compactMap { operation in
            guard case .failed(let message) = operation.state else { return nil }
            switch previous[operation.id] {
            case nil, .queued, .running, .paused, .cancelling: return (operation.title, message)
            default: return nil
            }
        }
    }

    // MARK: - Conflicts

    /// Asks on the frontmost browser window what to do about an existing item.
    private static func ask(_ conflict: Conflict) async -> (choice: ConflictChoice, applyToAll: Bool) {
        let alert = conflictAlert(conflict)
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
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard conflictChoices.indices.contains(index), conflictChoices[index] != .stop else {
            return (.stop, false)
        }
        return (conflictChoices[index], all)
    }

    /// The conflict question's answers, in the order of its buttons.
    static let conflictChoices: [ConflictChoice] = [.keepBoth, .replace, .replaceIfOlder, .skip, .stop]

    static func conflictAlert(_ conflict: Conflict) -> NSAlert {
        let alert = NSAlert()
        let name = conflict.existing.lastPathComponent
        let folder = conflict.existing.deletingLastPathComponent().lastPathComponent
        alert.messageText = "An item named “\(name)” already exists in “\(folder)”."
        var text = "Replacing moves the existing item to the Trash, so you can get it back."
        if let existing = conflict.existingModified, let incoming = conflict.incomingModified {
            let style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            text +=
                "\n\nExisting: modified \(existing.formatted(style))\nNew: modified \(incoming.formatted(style))"
        }
        text += "\n\nReplace If Older replaces only files whose existing copy is older."
        alert.informativeText = text
        for title in ["Keep Both", "Replace", "Replace If Older", "Skip", "Stop"] {
            alert.addButton(withTitle: title)
        }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to all"
        return alert
    }

    /// Asks before an undo moves files edited since to the Trash. They stay
    /// in the Trash, so Undo Anyway is the default (Return) and Cancel takes
    /// Escape, as in other Mac questions.
    private static func confirmUndo(changing items: [URL], on window: NSWindow?) async -> Bool {
        let alert = changedSinceAlert(items)
        let response: NSApplication.ModalResponse
        if let window, window.attachedSheet == nil {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn
    }

    static func changedSinceAlert(_ items: [URL]) -> NSAlert {
        let alert = NSAlert()
        if items.count == 1 {
            alert.messageText = "“\(items[0].lastPathComponent)” was changed after it was made. Undo anyway?"
            alert.informativeText = "Undo moves it to the Trash with the changes, so you can still get it back."
        } else {
            alert.messageText = "\(items.count) items were changed after they were made. Undo anyway?"
            alert.informativeText =
                "Undo moves them to the Trash with the changes, so you can still get them back.\n\n" + listing(items)
        }
        alert.addButton(withTitle: "Undo Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    // MARK: - Failures

    /// Asks what to do about an item that couldn't be copied or moved.
    private static func ask(_ failure: ItemFailure) async -> (choice: FailureChoice, applyToAll: Bool) {
        let alert = failureAlert(failure)
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let response: NSApplication.ModalResponse
        if let window, window.attachedSheet == nil {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn: return (.retry, false)
        case .alertSecondButtonReturn: return (.skip, alert.suppressionButton?.state == .on)
        default: return (.stop, false)
        }
    }

    static func failureAlert(_ failure: ItemFailure) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(failure.item.lastPathComponent)” couldn't be copied."
        alert.informativeText =
            failure.message + "\n\nNothing of it was left at the destination. Try again, skip it, or stop."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Stop")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Skip all failures"
        return alert
    }

    // MARK: - Disks without a Trash

    /// Asks before deleting items for good, on a disk with no Trash or for
    /// Delete Immediately. It names
    /// the disk and the items, and Cancel is the default: Return and Escape
    /// both keep the items. There is no "apply to all".
    private static func confirm(_ request: PermanentDeletion) async -> Bool {
        let alert = permanentDeletionAlert(request)
        // Cancel holds Return, so Escape, which NSAlert would give it, is
        // routed to it here.
        let cancel = alert.buttons[0]
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window === alert.window else { return event }
            cancel.performClick(nil)
            return nil
        }
        defer { escape.map(NSEvent.removeMonitor) }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let response: NSApplication.ModalResponse
        if let window, window.attachedSheet == nil {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        let confirmed = response == .alertSecondButtonReturn
        let outcome = confirmed ? "deleting" : "keeping"
        let why = request.reason == .noTrash ? "No Trash" : "Delete Immediately"
        logger.notice(
            "\(why, privacy: .public) on \(request.volume, privacy: .public): \(outcome, privacy: .public) \(request.items.count) items"
        )
        return confirmed
    }

    static func permanentDeletionAlert(_ request: PermanentDeletion) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .critical
        switch request.reason {
        case .noTrash:
            alert.messageText = "“\(request.volume)” has no Trash. Delete \(describe(request.items)) for good?"
        case .requested:
            alert.messageText = "Delete \(describe(request.items)) on “\(request.volume)” immediately?"
        }
        alert.informativeText =
            "Items deleted here are removed right away. They can't be put back, and this can't be undone.\n\n"
            + listing(request.items)
        // Cancel is the default: Return keeps the items.
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        let delete = alert.addButton(withTitle: "Delete Permanently")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        return alert
    }

    private static func describe(_ items: [URL]) -> String {
        items.count == 1 ? "“\(items[0].lastPathComponent)”" : "these \(items.count) items"
    }

    /// The items' names, one per line, up to ten.
    static func listing(_ items: [URL], limit: Int = 10) -> String {
        var lines = items.prefix(limit).map { "• " + $0.lastPathComponent }
        if items.count > limit { lines.append("…and \(items.count - limit) more") }
        return lines.joined(separator: "\n")
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
