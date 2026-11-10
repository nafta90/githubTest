import SwiftUI

/// Big, colour-coded countdown for the current phase.
struct IntervalView: View {
    @Environment(WorkoutManager.self) private var manager

    var body: some View {
        let phase = manager.currentSegment?.phase ?? .warmUp

        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(phase.title.uppercased())
                    .font(.headline)
                Spacer()
                if manager.state == .paused {
                    Text("PAUSED")
                        .font(.caption2.bold())
                        .foregroundStyle(.yellow)
                }
            }

            Text(TimeFormat.clock(Int(manager.remainingInPhase.rounded(.up))))
                .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text(roundText(for: phase))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            HStack {
                Label(manager.heartRate > 0 ? "\(Int(manager.heartRate))" : "--",
                      systemImage: "heart.fill")
                    .foregroundStyle(.pink)
                Spacer()
                Text(TimeFormat.clock(Int(manager.elapsed)))
                    .monospacedDigit()
                    .foregroundStyle(.yellow)
            }
            .font(.body)
        }
        .foregroundStyle(phase.color)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal)
    }

    private func roundText(for phase: Phase) -> String {
        if let round = phase.round {
            return "Round \(round) of \(manager.totalRounds)"
        }
        return "Then \(manager.totalRounds)× intervals"
    }
}
