import Foundation

/// The user's interval plan. All durations are in whole minutes.
/// Warm-up runs once, then (work → recovery) repeats `repeats` times.
struct IntervalPlan: Codable, Equatable {
    var warmUpMinutes: Int = 5
    var workMinutes: Int = 1
    var recoveryMinutes: Int = 3
    var repeats: Int = 6

    var totalMinutes: Int {
        warmUpMinutes + (workMinutes + recoveryMinutes) * repeats
    }

    /// Flat timeline of every phase, with start offsets in seconds.
    var schedule: [Segment] {
        var segments: [Segment] = []
        var offset: TimeInterval = 0

        if warmUpMinutes > 0 {
            let duration = TimeInterval(warmUpMinutes * 60)
            segments.append(Segment(phase: .warmUp, start: offset, duration: duration))
            offset += duration
        }

        for round in 1...max(repeats, 1) {
            let work = TimeInterval(workMinutes * 60)
            segments.append(Segment(phase: .work(round: round), start: offset, duration: work))
            offset += work

            let recovery = TimeInterval(recoveryMinutes * 60)
            if recovery > 0 {
                segments.append(Segment(phase: .recovery(round: round), start: offset, duration: recovery))
                offset += recovery
            }
        }

        return segments
    }

    // MARK: - Persistence

    private static let storageKey = "intervalPlan"

    static func load() -> IntervalPlan {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let plan = try? JSONDecoder().decode(IntervalPlan.self, from: data)
        else {
            return IntervalPlan()
        }
        return plan
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
