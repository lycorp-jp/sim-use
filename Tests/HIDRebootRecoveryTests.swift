// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

// Issue #55 regression: a simulator rebooted out-of-band must not leave
// the surviving per-UDID daemon sending HID events into the previous
// boot's dead mach port — the worst failure mode reported success while
// delivering nothing. The boot-identity gate (HIDBootIdentity +
// LaunchdSimLocator) must detect the new boot and rebuild the
// connection transparently.
//
// The suite reboots the shared simulator mid-run; it is safe under the
// sequential runner (scripts/test-runner.sh) which is the supported way
// to execute E2E suites.

@Suite("HID Reboot Recovery Tests", .serialized, .enabled(if: isE2EEnabled))
struct HIDRebootRecoveryTests {

    @Test("Tap through the same daemon still lands after simctl shutdown && boot", .timeLimit(.minutes(5)))
    func tapRecoversAcrossReboot() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()

        // 1. Baseline tap through the daemon; this also spawns it.
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        try await TestHelpers.runSimUseCommand("tap -x 200 -y 400", simulatorUDID: udid)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var uiState = try await TestHelpers.getUIState()
        var tapCount = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(tapCount?.label == "Tap Count: 1", "Baseline tap should land before the reboot")

        let daemonPIDBefore = try await daemonPID(for: udid)

        // 2. Reboot the simulator out-of-band; the daemon keeps running.
        _ = try await CommandRunner.run("xcrun simctl shutdown \(udid)", timeout: 120)
        do {
            _ = try await CommandRunner.run("xcrun simctl boot \(udid)", timeout: 120)
            _ = try await CommandRunner.run("xcrun simctl bootstatus \(udid)", timeout: 180)
        } catch {
            // Leaving the shared simulator shut down would cascade
            // unrelated failures through the rest of the sequential
            // run; best-effort re-boot before surfacing the real error.
            _ = try? await CommandRunner.run("xcrun simctl boot \(udid)", allowFailure: true, timeout: 120)
            _ = try? await CommandRunner.run("xcrun simctl bootstatus \(udid)", allowFailure: true, timeout: 180)
            throw error
        }

        // 3. Tap through the SAME daemon — no daemon stop, no respawn.
        // With a stale connection this reported success while the count
        // stayed 0; the boot-identity gate must rebuild instead.
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        try await TestHelpers.runSimUseCommand("tap -x 200 -y 400", simulatorUDID: udid)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        uiState = try await TestHelpers.getUIState()
        tapCount = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(tapCount?.label == "Tap Count: 1", "Tap after reboot should land through the rebuilt HID connection")

        // Guard against vacuity: if the daemon died and respawned along
        // the way, step 3 exercised a fresh process instead of the
        // cached-connection path this suite exists to cover.
        let daemonPIDAfter = try await daemonPID(for: udid)
        #expect(daemonPIDBefore == daemonPIDAfter, "The daemon must survive the reboot for this test to be meaningful")
    }

    /// The per-UDID daemon's pid, read from its pidfile under the
    /// daemon runtime directory (`/tmp/sim-use-<uid>/<udid>.pid`).
    private func daemonPID(for udid: String) async throws -> String {
        let (output, exitCode) = try await CommandRunner.run(
            "cat /tmp/sim-use-$(id -u)/\(udid).pid",
            allowFailure: true
        )
        guard exitCode == 0, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TestError.unexpectedState("No daemon pidfile for \(udid); did the baseline tap spawn a daemon?")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
