import Foundation
import HealthKit
import Observation

enum SessionState {
    case idle, running, paused, ending, ended
}

/// Runs the HealthKit workout session and drives the interval timeline.
///
/// Phase changes are computed from the workout's *active* elapsed time
/// (pauses excluded), so the schedule stays correct even if the app is
/// briefly throttled in the background.
@MainActor
@Observable
final class WorkoutManager: NSObject {
    // MARK: - Plan

    var plan: IntervalPlan = IntervalPlan.load() {
        didSet { plan.save() }
    }

    // MARK: - Live state

    private(set) var state: SessionState = .idle
    private(set) var schedule: [Segment] = []
    private(set) var currentIndex = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var errorMessage: String?

    private(set) var heartRate: Double = 0
    private(set) var averageHeartRate: Double = 0
    private(set) var activeEnergy: Double = 0   // kcal
    private(set) var distance: Double = 0       // meters
    private(set) var workout: HKWorkout?

    var currentSegment: Segment? {
        schedule.indices.contains(currentIndex) ? schedule[currentIndex] : nil
    }

    var remainingInPhase: TimeInterval {
        guard let segment = currentSegment else { return 0 }
        return max(segment.end - elapsed, 0)
    }

    var totalRounds: Int {
        schedule.filter { segment in
            if case .work = segment.phase { return true }
            return false
        }.count
    }

    // MARK: - Private

    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var segmentStartDate: Date?
    @ObservationIgnored private var lastCountdownSecond: Int?

    // MARK: - Authorization

    func requestAuthorization() async throws {
        let toShare: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
        ]
        let toRead: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
        ]
        try await healthStore.requestAuthorization(toShare: toShare, read: toRead)
    }

    // MARK: - Controls

    func start() async {
        guard state == .idle else { return }
        errorMessage = nil

        do {
            try await requestAuthorization()

            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .running
            configuration.locationType = .outdoor

            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                         workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder

            resetMetrics()
            schedule = plan.schedule
            currentIndex = 0
            lastCountdownSecond = nil

            let startDate = Date()
            segmentStartDate = startDate
            session.startActivity(with: startDate)
            try await builder.beginCollection(at: startDate)

            state = .running
            if let first = schedule.first {
                Haptics.phaseStarted(first.phase)
            }
            startTimer()
        } catch {
            errorMessage = error.localizedDescription
            session = nil
            builder = nil
            state = .idle
        }
    }

    func togglePause() {
        switch state {
        case .running:
            session?.pause()
            state = .paused
        case .paused:
            session?.resume()
            state = .running
        default:
            break
        }
    }

    func end() {
        guard state == .running || state == .paused else { return }
        markSegmentEnded(at: Date())
        stopTimer()
        state = .ending
        session?.end()
    }

    /// Back to the setup screen after the summary.
    func reset() {
        stopTimer()
        session = nil
        builder = nil
        workout = nil
        schedule = []
        currentIndex = 0
        elapsed = 0
        errorMessage = nil
        resetMetrics()
        state = .idle
    }

    // MARK: - Timeline

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard state == .running || state == .paused, let builder else { return }
        let now = Date()
        elapsed = builder.elapsedTime(at: now)
        guard state == .running else { return }

        // Whole plan completed.
        guard let newIndex = schedule.firstIndex(where: { elapsed < $0.end }) else {
            Haptics.finished()
            end()
            return
        }

        // Phase switch.
        if newIndex != currentIndex {
            markSegmentEnded(at: now)
            currentIndex = newIndex
            segmentStartDate = now
            lastCountdownSecond = nil
            Haptics.phaseStarted(schedule[newIndex].phase)
            return
        }

        // 3-2-1 countdown before the next switch.
        let secondsLeft = Int((schedule[currentIndex].end - elapsed).rounded(.up))
        if (1...3).contains(secondsLeft), secondsLeft != lastCountdownSecond {
            lastCountdownSecond = secondsLeft
            Haptics.countdownTick()
        }
    }

    /// Adds a segment marker so the Fitness app shows each interval as a split.
    private func markSegmentEnded(at endDate: Date) {
        guard let start = segmentStartDate, let builder, let segment = currentSegment else { return }
        segmentStartDate = nil
        let label = segment.phase.round.map { "\(segment.phase.title) \($0)" } ?? segment.phase.title
        let event = HKWorkoutEvent(type: .segment,
                                   dateInterval: DateInterval(start: start, end: max(endDate, start)),
                                   metadata: ["IntervalPhase": label])
        builder.addWorkoutEvents([event]) { _, _ in }
    }

    // MARK: - Finishing

    private func finish(at date: Date) async {
        guard let builder else {
            state = .ended
            return
        }
        do {
            try await builder.endCollection(at: date)
            workout = try await builder.finishWorkout()
        } catch {
            errorMessage = error.localizedDescription
        }
        state = .ended
    }

    // MARK: - Metrics

    private func resetMetrics() {
        heartRate = 0
        averageHeartRate = 0
        activeEnergy = 0
        distance = 0
    }

    private func update(with statistics: HKStatistics) {
        switch statistics.quantityType {
        case HKQuantityType(.heartRate):
            let bpm = HKUnit.count().unitDivided(by: .minute())
            heartRate = statistics.mostRecentQuantity()?.doubleValue(for: bpm) ?? 0
            averageHeartRate = statistics.averageQuantity()?.doubleValue(for: bpm) ?? 0
        case HKQuantityType(.activeEnergyBurned):
            activeEnergy = statistics.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
        case HKQuantityType(.distanceWalkingRunning):
            distance = statistics.sumQuantity()?.doubleValue(for: .meter()) ?? 0
        default:
            break
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        guard toState == .ended else { return }
        Task { @MainActor in
            await self.finish(at: date)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.errorMessage = message
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        for type in collectedTypes {
            guard
                let quantityType = type as? HKQuantityType,
                let statistics = workoutBuilder.statistics(for: quantityType)
            else { continue }
            Task { @MainActor in
                self.update(with: statistics)
            }
        }
    }
}
