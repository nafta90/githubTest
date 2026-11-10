import SwiftUI

/// Swipe right for controls, main page shows the current interval.
struct SessionPagingView: View {
    private enum Page { case controls, interval }
    @State private var selection: Page = .interval

    var body: some View {
        TabView(selection: $selection) {
            ControlsView().tag(Page.controls)
            IntervalView().tag(Page.interval)
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
    }
}

struct ControlsView: View {
    @Environment(WorkoutManager.self) private var manager

    var body: some View {
        let isPaused = manager.state == .paused

        HStack(spacing: 16) {
            VStack {
                Button {
                    manager.end()
                } label: {
                    Image(systemName: "xmark")
                }
                .tint(.red)
                .font(.title2)
                Text("End")
            }

            VStack {
                Button {
                    manager.togglePause()
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                }
                .tint(.yellow)
                .font(.title2)
                Text(isPaused ? "Resume" : "Pause")
            }
        }
    }
}
