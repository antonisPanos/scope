import SwiftUI

/// The toolbar button for the activity drawer. While operations run it shows
/// a ring filling with their overall progress.
struct ActivityRing: View {
    let controller: OperationsController
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let fraction = controller.overallFraction {
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
                    Circle().trim(from: 0, to: max(0.02, fraction))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: fraction)
                } else {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(controller.active.isEmpty ? "Activity" : "\(controller.active.count) operation\(controller.active.count == 1 ? "" : "s") running")
    }
}
