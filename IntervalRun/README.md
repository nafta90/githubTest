# Interval Run — Apple Watch app

Interval running with repeats, for Apple Watch (watchOS 10+), written in SwiftUI.

### What it does
- **Warm-up once**, then **work → recovery repeated N times** (all set in whole minutes).
  - Default: 5 min warm-up, 1 min work, 3 min recovery × 6 = 29 min.
- **Haptic feedback** on every switch (works with the screen off):
  - **Work starts:** strong triple tap.
  - **Recovery starts:** softer descending tap.
  - **Last 3 seconds** of each phase: light click each second.
  - **Finished:** double success tap.
- **Saved as an outdoor run** in Health / Fitness, with each interval stored as a segment.
- **Live screen:** colour-coded phase (blue warm-up, red work, green recovery), countdown, round X of N, heart rate, total time.
- **Swipe right** for Pause / End.
- Your last plan is remembered.

### Project layout
- `project.yml` — XcodeGen project spec (HealthKit entitlement, background workout mode, Health usage strings).
- `Sources/IntervalRunApp.swift` — app entry + screen routing.
- `Sources/Model/` — `IntervalPlan` (settings + timeline) and `Phase`.
- `Sources/Workout/WorkoutManager.swift` — HealthKit workout session and interval engine.
- `Sources/Workout/Haptics.swift` — the vibration patterns.
- `Sources/Views/` — Setup, live interval, controls and summary screens.

### Build — option A: XcodeGen (quickest)
1. Install XcodeGen:
   ```bash
   brew install xcodegen
   ```
2. Generate the project:
   ```bash
   cd IntervalRun && xcodegen
   ```
3. Open `IntervalRun.xcodeproj`, select the **IntervalRun** target → **Signing & Capabilities** → choose your **Team**.
   - If needed, change the bundle ID (`com.example.IntervalRun`) to something unique.
4. Pick your paired Apple Watch (or a watchOS Simulator) and press **Run**.

### Build — option B: new Xcode project
1. **File → New → Project → watchOS → App**, name it `IntervalRun`, choose **Watch-only App**, interface **SwiftUI**.
2. Delete the generated `ContentView.swift` and app file; drag in everything from `Sources/`.
3. **Signing & Capabilities**:
   - Add **HealthKit**.
   - Add **Background Modes** → tick **Workout processing**.
4. **Info** tab, add:
   - `NSHealthShareUsageDescription` — e.g. "Reads heart rate, distance and energy during your run."
   - `NSHealthUpdateUsageDescription` — e.g. "Saves your interval runs to Health."
5. Set deployment target to **watchOS 10.0** and Run.

### Quick test
- In the Simulator or on the watch, set **Warm-up Off, Work 1, Recovery 1, Repeats 2**.
- Check: countdown clicks, work/recovery haptics, "Round 1 of 2", summary at the end.
- On a real run, confirm the workout shows up in the Fitness app on your iPhone.
