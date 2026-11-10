import SwiftUI

/// Pick warm-up / work / recovery (whole minutes) and number of repeats.
struct SetupView: View {
    @Environment(WorkoutManager.self) private var manager
    @State private var isStarting = false

    var body: some View {
        @Bindable var manager = manager

        List {
            Section {
                minutesPicker("Warm-up", systemImage: "figure.walk",
                              selection: $manager.plan.warmUpMinutes, range: 0...30, tint: .blue)
                minutesPicker("Work", systemImage: "flame.fill",
                              selection: $manager.plan.workMinutes, range: 1...30, tint: .red)
                minutesPicker("Recovery", systemImage: "wind",
                              selection: $manager.plan.recoveryMinutes, range: 1...30, tint: .green)

                Picker(selection: $manager.plan.repeats) {
                    ForEach(1...30, id: \.self) { count in
                        Text("\(count)×").tag(count)
                    }
                } label: {
                    Label("Repeats", systemImage: "repeat")
                }
                .pickerStyle(.navigationLink)
            } footer: {
                Text("Total \(manager.plan.totalMinutes) min")
            }

            if let error = manager.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                isStarting = true
                Task {
                    await manager.start()
                    isStarting = false
                }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.green)
            .disabled(isStarting)
        }
        .navigationTitle("Intervals")
    }

    private func minutesPicker(_ title: String,
                               systemImage: String,
                               selection: Binding<Int>,
                               range: ClosedRange<Int>,
                               tint: Color) -> some View {
        Picker(selection: selection) {
            ForEach(Array(range), id: \.self) { minutes in
                Text(minutes == 0 ? "Off" : "\(minutes) min").tag(minutes)
            }
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
        }
        .pickerStyle(.navigationLink)
    }
}
