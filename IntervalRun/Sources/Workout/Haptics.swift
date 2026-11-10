import WatchKit

/// Distinct wrist taps so you can tell phases apart without looking.
enum Haptics {
    static func phaseStarted(_ phase: Phase) {
        switch phase {
        case .warmUp:
            play([.start])
        case .work:
            // Strong, triple tap: time to push.
            play([.start, .notification, .notification])
        case .recovery:
            // Softer, descending: ease off.
            play([.stop, .directionDown])
        }
    }

    /// Light tick in the last 3 seconds before a switch.
    static func countdownTick() {
        play([.click])
    }

    static func finished() {
        play([.success, .success])
    }

    /// Haptics fired back-to-back get merged by the system, so space them out.
    private static func play(_ types: [WKHapticType], spacing: TimeInterval = 0.7) {
        for (index, type) in types.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * spacing) {
                WKInterfaceDevice.current().play(type)
            }
        }
    }
}
