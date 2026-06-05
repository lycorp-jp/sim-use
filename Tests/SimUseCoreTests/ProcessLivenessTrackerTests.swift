// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import Foundation
import Testing

@Suite("ProcessLivenessTracker — crash/termination detection")
struct ProcessLivenessTrackerTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func snap(_ pairs: [Int: String]) -> AppSnapshot { AppSnapshot(appsByPid: pairs) }

    // MARK: - Baseline

    @Test("First observation baselines silently, emits no event")
    func firstObservationBaselines() {
        let tracker = ProcessLivenessTracker(activeWindow: 120)
        let events = tracker.evaluate(current: snap([100: "com.example.app"]), now: t0)
        #expect(events.isEmpty)
        #expect(tracker.pending.isEmpty)
    }

    // MARK: - Backgrounding (the false-positive we must NOT raise)

    @Test("A live process that merely backgrounds raises no event")
    func backgroundingIsSilent() {
        let tracker = ProcessLivenessTracker(activeWindow: 120)
        _ = tracker.evaluate(current: snap([100: "com.example.app"]), now: t0)
        // Same pid still present (app alive, just not foreground).
        let events = tracker.evaluate(current: snap([100: "com.example.app"]), now: t0.addingTimeInterval(5))
        #expect(events.isEmpty)
        #expect(tracker.pending.isEmpty)
    }

    // MARK: - Disappearance within the active window

    @Test("A process that disappears during active driving is a high-confidence death, latched")
    func disappearanceWithinWindow() {
        let tracker = ProcessLivenessTracker(activeWindow: 120)
        _ = tracker.evaluate(current: snap([100: "com.example.app"]), now: t0)
        let events = tracker.evaluate(current: snap([:]), now: t0.addingTimeInterval(10))
        #expect(events.count == 1)
        #expect(events.first?.kind == .disappeared)
        #expect(events.first?.bundleId == "com.example.app")
        #expect(events.first?.pid == 100)
        #expect(events.first?.confidence == .high)
        #expect(tracker.pending["com.example.app"] != nil)
    }

    // MARK: - Disappearance after an idle gap (out-of-band kill — quiet)

    @Test("A disappearance after an idle gap is low-confidence and NOT latched")
    func disappearanceAfterIdleGap() {
        let tracker = ProcessLivenessTracker(activeWindow: 120)
        _ = tracker.evaluate(current: snap([100: "com.example.app"]), now: t0)
        // 300s later — well beyond the active window; likely an
        // out-of-band kill (user force-quit / Xcode stop) during idle.
        let events = tracker.evaluate(current: snap([:]), now: t0.addingTimeInterval(300))
        #expect(events.count == 1)
        #expect(events.first?.kind == .changedWhileIdle)
        #expect(events.first?.confidence == .low)
        #expect(tracker.pending.isEmpty)
    }

    // MARK: - Crash-and-relaunch

    @Test("Same bundle with a new pid is a replaced (crash-and-relaunch) event, not left pending")
    func crashAndRelaunch() {
        let tracker = ProcessLivenessTracker(activeWindow: 120)
        _ = tracker.evaluate(current: snap([100: "com.example.app"]), now: t0)
        let events = tracker.evaluate(current: snap([200: "com.example.app"]), now: t0.addingTimeInterval(10))
        #expect(events.count == 1)
        #expect(events.first?.kind == .replaced)
        #expect(events.first?.bundleId == "com.example.app")
        // App is alive again under a new pid → no sticky latch.
        #expect(tracker.pending.isEmpty)
    }

    // MARK: - Recovery clears the latch

    @Test("Reappearance after a latched death clears the pending latch")
    func recoveryClearsPending() {
        let tracker = ProcessLivenessTracker(activeWindow: 120)
        _ = tracker.evaluate(current: snap([100: "com.example.app"]), now: t0)
        _ = tracker.evaluate(current: snap([:]), now: t0.addingTimeInterval(10))
        #expect(tracker.pending["com.example.app"] != nil)
        // App relaunches under a new pid on a later command.
        let events = tracker.evaluate(current: snap([200: "com.example.app"]), now: t0.addingTimeInterval(20))
        #expect(events.isEmpty)               // nothing died this step
        #expect(tracker.pending.isEmpty)       // latch cleared by recovery
    }

    // MARK: - Reset

    @Test("reset re-baselines and clears the latch")
    func resetRebaselines() {
        let tracker = ProcessLivenessTracker(activeWindow: 120)
        _ = tracker.evaluate(current: snap([100: "com.example.app"]), now: t0)
        _ = tracker.evaluate(current: snap([:]), now: t0.addingTimeInterval(10))
        #expect(tracker.pending.isEmpty == false)
        tracker.reset(to: snap([300: "com.other.app"]), now: t0.addingTimeInterval(20))
        #expect(tracker.pending.isEmpty)
        // After reset the new set is the baseline: the absent line app
        // must NOT be re-reported on the next evaluate.
        let events = tracker.evaluate(current: snap([300: "com.other.app"]), now: t0.addingTimeInterval(25))
        #expect(events.isEmpty)
    }

    // MARK: - Multiple apps

    @Test("Only the disappearing app emits; survivors are silent")
    func onlyDeadAppEmits() {
        let tracker = ProcessLivenessTracker(activeWindow: 120)
        _ = tracker.evaluate(current: snap([100: "com.example.app", 101: "com.keep.alive"]), now: t0)
        let events = tracker.evaluate(current: snap([101: "com.keep.alive"]), now: t0.addingTimeInterval(5))
        #expect(events.count == 1)
        #expect(events.first?.bundleId == "com.example.app")
    }

    // MARK: - Snapshot liveness query (for app-state)

    @Test("AppSnapshot reports liveness of a bundle id")
    func snapshotLiveness() {
        let s = snap([100: "com.example.app"])
        #expect(s.liveness(ofBundleId: "com.example.app") == .alive(pid: 100))
        #expect(s.liveness(ofBundleId: "com.absent.app") == .dead)
    }
}