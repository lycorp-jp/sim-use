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

        // 4. A Resize Mode session after the reboot, through the same
        // daemon (R158-04): display UUIDs change per boot, so the session's
        // display must be found despite the topology cached before the
        // reboot. Skipped where CoreDevice cannot host a session.
        if let session = try await startResizeSession(udid: udid) {
            defer { if session.isRunning { session.terminate() } }
            // A raw tap alone can ride the "no session" answer step 3 just
            // cached (documented 5 s window); `ui` sees the new scene.
            _ = try await TestHelpers.runSimUseCommand("ui", simulatorUDID: udid)
            try await TestHelpers.runSimUseCommand("tap -x 100 -y 300", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            uiState = try await TestHelpers.getUIState()
            let location = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Location:")
            #expect(location?.label == "Tap Location: (100, 300)", "A tap in a post-reboot Resize Mode session should land at the scene point")
            session.terminate()
            while session.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // Guard against vacuity: if the daemon died and respawned along
        // the way, step 3 exercised a fresh process instead of the
        // cached-connection path this suite exists to cover.
        let daemonPIDAfter = try await daemonPID(for: udid)
        #expect(daemonPIDBefore == daemonPIDAfter, "The daemon must survive the reboot for this test to be meaningful")
    }

    /// Starts `devicectl device appResize start` (560x874) and waits for
    /// CoreDevice to report the session; nil where it cannot host one.
    private func startResizeSession(udid: String) async throws -> Process? {
        func active() async -> Bool? {
            guard let (output, _) = try? await CommandRunner.run(
                "xcrun devicectl device info appResize --device \(udid) --json-output - --timeout 5 --quiet 2>/dev/null",
                allowFailure: true
            ), let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else { return nil }
            if json["result"] != nil { return true }
            if let error = json["error"] as? [String: Any], (error["code"] as? Int) == 24004 { return false }
            return nil
        }
        guard await active() != nil else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "device", "appResize", "start", "--device", udid, "--preferred-size", "560x874"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<20 {
            if await active() == true { return process }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        process.terminate()
        throw TestError.unexpectedState("devicectl appResize start did not produce an active session within 10 s")
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
