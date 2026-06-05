// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import Foundation
import Testing

/// Pins the probe-failure handling that keeps a flaky `launchctl` / `adb`
/// probe from faking a crash (issue #81). The fix routes every dispatched
/// command through `DaemonDispatch.evaluateAdvisory`, which treats a `nil`
/// snapshot as "unknown — skip", never as "everything died".
@Suite("DaemonDispatch.evaluateAdvisory — probe-failure handling")
struct DaemonProcessAdvisoryTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func snap(_ pairs: [Int: String]) -> AppSnapshot { AppSnapshot(appsByPid: pairs) }

    @Test("A nil snapshot yields no advisory and leaves the baseline untouched")
    func nilSnapshotIsSkipped() {
        let tracker = ProcessLivenessTracker(activeWindow: 120)
        // Baseline: target app alive.
        _ = DaemonDispatch.evaluateAdvisory(snapshot: snap([42: "com.x"]), tracker: tracker, now: t0)
        // The next command's probe fails (transient launchctl/adb error).
        let advisory = DaemonDispatch.evaluateAdvisory(
            snapshot: nil, tracker: tracker, now: t0.addingTimeInterval(1)
        )
        #expect(advisory == nil)
        // Baseline must NOT be poisoned to the empty set.
        #expect(tracker.previous == snap([42: "com.x"]))
    }

    @Test("A failed probe between two good ones does not fake a disappearance")
    func failedProbeDoesNotFakeDisappearance() {
        let tracker = ProcessLivenessTracker(activeWindow: 120)
        _ = DaemonDispatch.evaluateAdvisory(snapshot: snap([42: "com.x"]), tracker: tracker, now: t0)
        _ = DaemonDispatch.evaluateAdvisory(snapshot: nil, tracker: tracker, now: t0.addingTimeInterval(1))
        // App still alive on the next good probe → nothing disappeared.
        let advisory = DaemonDispatch.evaluateAdvisory(
            snapshot: snap([42: "com.x"]), tracker: tracker, now: t0.addingTimeInterval(2)
        )
        #expect(advisory == nil)
        #expect(tracker.pending.isEmpty)
    }

    @Test("A genuine disappearance after a real snapshot is still reported")
    func realDisappearanceStillReported() {
        let tracker = ProcessLivenessTracker(activeWindow: 120)
        _ = DaemonDispatch.evaluateAdvisory(snapshot: snap([42: "com.x"]), tracker: tracker, now: t0)
        let advisory = DaemonDispatch.evaluateAdvisory(
            snapshot: snap([:]), tracker: tracker, now: t0.addingTimeInterval(1)
        )
        #expect(advisory?.events.first?.kind == .disappeared)
        #expect(advisory?.events.first?.bundleId == "com.x")
    }
}