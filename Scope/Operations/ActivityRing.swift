import ScopeEngine
import SwiftUI

/// The toolbar button for the activity drawer. While operations run it shows
/// a ring filling with their overall progress; it widens to show how many
/// operations you haven't looked at yet.
struct ActivityRing: View {
    let controller: OperationsController
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    if let fraction = controller.overallFraction {
                        Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
                        Circle().trim(from: 0, to: max(0.02, fraction))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.1), value: fraction)
                    } else {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                .frame(width: 16, height: 16)
                if controller.unreadCount > 0 {
                    Text("\(controller.unreadCount)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .contentShape(Rectangle())
            .animation(.spring(duration: 0.3), value: controller.unreadCount)
        }
        .buttonStyle(.borderless)
        .help(controller.active.isEmpty ? "Activity (⌥⌘A)" : "\(controller.active.count) operation\(controller.active.count == 1 ? "" : "s") running")
    }
}

/// The footer's live line: what is running now ("Copying 3 items to names ·
/// 42%"), or briefly what just finished. Clicking it opens the activity drawer.
struct FooterActivity: View {
    let controller: OperationsController
    var action: () -> Void

    var body: some View {
        // Re-evaluated twice a second so a finished message fades away on time.
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            if let snapshot = controller.footerSnapshot {
                Button(action: action) {
                    HStack(spacing: 6) {
                        icon(for: snapshot)
                        Text(text(for: snapshot))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(color(for: snapshot))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show Activity")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: controller.footerSnapshot?.id)
        .animation(.easeOut(duration: 0.25), value: controller.footerSnapshot?.state)
    }

    @ViewBuilder
    private func icon(for snapshot: OperationCenter.Snapshot) -> some View {
        switch snapshot.state {
        case .running, .cancelling:
            if let fraction = snapshot.progress.fraction {
                ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.mini)
            } else {
                ProgressView().controlSize(.mini)
            }
        case .paused: Image(systemName: "pause.circle")
        case .failed: Image(systemName: "exclamationmark.triangle.fill")
        case .cancelled: Image(systemName: "xmark.circle")
        default: Image(systemName: "checkmark.circle.fill").symbolEffect(.bounce, value: snapshot.id)
        }
    }

    private func text(for snapshot: OperationCenter.Snapshot) -> String {
        let progress = snapshot.progress
        switch snapshot.state {
        case .running, .paused, .cancelling:
            var parts = [snapshot.title]
            if progress.itemsTotal > 1 { parts.append("\(progress.itemsDone) of \(progress.itemsTotal)") }
            if let fraction = progress.fraction { parts.append("\(Int(fraction * 100))%") }
            if snapshot.state == .paused { parts.append("paused") }
            if snapshot.state == .cancelling { parts.append("cancelling") }
            let queued = controller.active.count - 1
            if queued > 0 { parts.append("+\(queued) more") }
            return parts.joined(separator: " · ")
        case .failed(let message): return "Failed: \(message)"
        case .cancelled: return "Cancelled: \(snapshot.title)"
        default: return "Done: \(snapshot.title)"
        }
    }

    private func color(for snapshot: OperationCenter.Snapshot) -> Color {
        switch snapshot.state {
        case .failed: Color(nsColor: Palette.error)
        case .cancelled: Color(nsColor: Palette.warning)
        default: Color(nsColor: Palette.secondaryText)
        }
    }
}
