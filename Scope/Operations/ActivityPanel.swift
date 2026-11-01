import ScopeEngine
import SwiftUI

/// The activity drawer at the bottom of each window: every operation with
/// what it is, its progress, speed, time running and time left, and its
/// state; queued ones with their place in line; finished ones with any
/// errors and an Undo button.
struct ActivityPanel: View {
    let controller: OperationsController
    var onUndo: (UUID) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                if controller.snapshots.contains(where: { !$0.isActive }) {
                    Button("Clear Finished") { controller.clearFinished() }
                        .buttonStyle(.borderless)
                }
                Button {
                    onClose()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Hide Activity")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            if controller.snapshots.isEmpty {
                Text("No operations yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(controller.snapshots.reversed()) { snapshot in
                            OperationRow(snapshot: snapshot, controller: controller, onUndo: onUndo)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: Palette.panelBackground))
    }
}

private struct OperationRow: View {
    let snapshot: OperationCenter.Snapshot
    let controller: OperationsController
    var onUndo: (UUID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title).lineLimit(1).truncationMode(.middle)
                if showsProgress {
                    ProgressView(value: snapshot.progress.fraction ?? 0)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if !snapshot.progress.currentItem.isEmpty, snapshot.state == .running {
                    Text(snapshot.progress.currentItem).font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if !snapshot.skippedEntries.isEmpty {
                    Text(
                        "Skipped \(snapshot.skippedEntries.count) unsafe archive \(snapshot.skippedEntries.count == 1 ? "entry" : "entries"): \(snapshot.skippedEntries.prefix(3).joined(separator: ", "))"
                    )
                    .font(.caption).foregroundStyle(Color(nsColor: Palette.warning)).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            buttons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 6) {
            switch snapshot.state {
            case .queued:
                Button {
                    controller.move(snapshot.id, by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }.help("Move up")
                Button {
                    controller.move(snapshot.id, by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }.help("Move down")
                Button("Start Now") { controller.startNow(snapshot.id) }
                Button("Remove") { controller.cancel(snapshot.id) }
            case .running:
                Button("Pause") { controller.pause(snapshot.id) }
                Button("Cancel") { controller.cancel(snapshot.id) }
            case .paused:
                Button("Resume") { controller.resume(snapshot.id) }
                Button("Cancel") { controller.cancel(snapshot.id) }
            case .cancelling:
                // Stays disabled until the operation has fully stopped.
                Button("Cancelling…") {}.disabled(true)
            case .done, .failed, .cancelled:
                if snapshot.canUndo {
                    Button("Undo") { onUndo(snapshot.id) }
                }
            }
        }
        .controlSize(.small)
    }

    private var showsProgress: Bool {
        switch snapshot.state {
        case .running, .paused, .cancelling: true
        default: false
        }
    }

    private var icon: String {
        switch snapshot.state {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle"
        case .cancelling: "xmark.circle"
        case .done: snapshot.isUndo ? "arrow.uturn.backward.circle" : "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        }
    }

    private var tint: Color {
        switch snapshot.state {
        case .failed: Color(nsColor: Palette.error)
        case .cancelled, .cancelling: Color(nsColor: Palette.warning)
        case .done: Color.accentColor
        default: .secondary
        }
    }

    private var detail: String {
        let progress = snapshot.progress
        var parts: [String] = []
        switch snapshot.state {
        case .queued:
            parts.append("Waiting\(snapshot.queuePosition.map { ", number \($0) in line" } ?? "")")
        case .running, .paused, .cancelling:
            if progress.itemsTotal > 0 { parts.append("\(progress.itemsDone) of \(progress.itemsTotal) items") }
            if progress.bytesTotal > 0 {
                parts.append("\(Self.bytes(progress.bytesDone)) of \(Self.bytes(progress.bytesTotal))")
            }
            if let speed = snapshot.speed, speed > 0 { parts.append("\(Self.bytes(Int64(speed)))/s") }
            if let started = snapshot.started {
                parts.append("running \(Self.duration(Date().timeIntervalSince(started)))")
            }
            if let left = snapshot.timeRemaining, snapshot.state == .running {
                parts.append("about \(Self.duration(left)) left")
            }
            if snapshot.state == .paused { parts.append("paused") }
        case .done:
            parts.append(snapshot.isUndo ? "Undone" : "Done")
            if let started = snapshot.started, let finished = snapshot.finished {
                parts.append("took \(Self.duration(finished.timeIntervalSince(started)))")
            }
        case .failed(let message):
            parts.append("Failed: \(message)")
        case .cancelled:
            parts.append(snapshot.canUndo ? "Cancelled; finished items can be undone" : "Cancelled")
        }
        return parts.joined(separator: " · ")
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min \(total % 60) s" }
        return "\(total / 3600) h \(total / 60 % 60) min"
    }
}
