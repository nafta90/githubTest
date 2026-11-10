import SwiftUI

enum Phase: Equatable {
    case warmUp
    case work(round: Int)
    case recovery(round: Int)

    var title: String {
        switch self {
        case .warmUp: "Warm-up"
        case .work: "Work"
        case .recovery: "Recovery"
        }
    }

    var round: Int? {
        switch self {
        case .warmUp: nil
        case .work(let round), .recovery(let round): round
        }
    }

    var color: Color {
        switch self {
        case .warmUp: .blue
        case .work: .red
        case .recovery: .green
        }
    }
}

/// One phase on the workout timeline. Times are seconds of active workout time.
struct Segment: Equatable {
    let phase: Phase
    let start: TimeInterval
    let duration: TimeInterval

    var end: TimeInterval { start + duration }
}

enum TimeFormat {
    /// "m:ss" or "h:mm:ss".
    static func clock(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }
}
