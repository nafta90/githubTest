import SwiftUI

struct SummaryView: View {
    @Environment(WorkoutManager.self) private var manager

    var body: some View {
        let plan = manager.plan
        let duration = manager.workout?.duration ?? manager.elapsed

        List {
            row("Total time", TimeFormat.clock(Int(duration)), color: .yellow)
            row("Distance",
                Measurement(value: manager.distance, unit: UnitLength.meters)
                    .formatted(.measurement(width: .abbreviated, usage: .road)),
                color: .green)
            row("Avg heart rate",
                manager.averageHeartRate > 0 ? "\(Int(manager.averageHeartRate)) bpm" : "--",
                color: .pink)
            row("Active energy", "\(Int(manager.activeEnergy)) kcal", color: .orange)
            row("Plan",
                "\(plan.warmUpMinutes) + \(plan.repeats)×(\(plan.workMinutes)/\(plan.recoveryMinutes)) min",
                color: .blue)

            if let error = manager.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button("Done") {
                manager.reset()
            }
        }
        .navigationTitle("Summary")
    }

    private func row(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
                .foregroundStyle(color)
        }
    }
}
