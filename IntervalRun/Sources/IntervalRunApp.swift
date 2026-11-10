import SwiftUI

@main
struct IntervalRunApp: App {
    @State private var manager = WorkoutManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(manager)
        }
    }
}

/// Routes between the setup screen, the live session and the summary.
struct ContentView: View {
    @Environment(WorkoutManager.self) private var manager

    var body: some View {
        switch manager.state {
        case .idle:
            NavigationStack {
                SetupView()
            }
        case .running, .paused:
            SessionPagingView()
        case .ending:
            ProgressView("Saving workout…")
        case .ended:
            NavigationStack {
                SummaryView()
            }
        }
    }
}
