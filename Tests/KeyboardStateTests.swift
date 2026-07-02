// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import ArgumentParser
import Foundation
import Testing
@testable import SimUseCore

// Regression coverage for LINEIOS-216939: `resolveDeferredArguments()`
// must copy the explicit `--device`/`--udid` into `device.resolved`
// before dispatch. The protocol-default `run()` wires that for every
// command (KeyboardState no longer overrides it). If resolution is
// skipped, `device.resolved` stays "" and every dispatch fails with
// `"Simulator with UDID  not found in set."` (note the double space —
// the empty UDID).

@Suite("KeyboardState — resolveDeferredArguments wiring")
struct KeyboardStateResolveTests {
    @Test("parsed KeyboardState starts with empty resolved device id")
    func parsedDefaultsAreEmpty() throws {
        let cmd = try KeyboardState.parse(["--device", "FAKE-UDID"])
        // `device.resolved` is set by resolveDeferredArguments; until
        // then it stays at its default empty string. `device.device`
        // is the ArgumentParser-bound value.
        #expect(cmd.device.resolved == "")
        #expect(cmd.device.device == "FAKE-UDID")
    }

    @Test("resolveDeferredArguments copies explicit --device into resolved")
    func explicitDeviceIsResolved() throws {
        var cmd = try KeyboardState.parse(["--device", "FAKE-UDID"])
        try cmd.resolveDeferredArguments()
        #expect(cmd.device.resolved == "FAKE-UDID")
    }

    @Test("legacy --udid alias still resolves the device id")
    func legacyUDIDFlagStillResolves() throws {
        var cmd = try KeyboardState.parse(["--udid", "FAKE-UDID"])
        try cmd.resolveDeferredArguments()
        #expect(cmd.device.resolved == "FAKE-UDID")
    }

    @Test("resolveDeferredArguments trims surrounding whitespace on --device")
    func explicitDeviceIsTrimmed() throws {
        var cmd = try KeyboardState.parse(["--device", "  FAKE-UDID  "])
        try cmd.resolveDeferredArguments()
        #expect(cmd.device.resolved == "FAKE-UDID")
    }
}

// End-to-end coverage that the resolved UDID reaches dispatch: the
// explicit value must echo back inside the failure surface. Pre-fix (a
// custom `run()` that skipped resolution) the message carried an empty
// UDID (`UDID  not found`); with the protocol-default `run()` it carries
// the value that was passed. Runs against a host with no matching
// simulator, so the call fails — the assertion is on which UDID the
// failure names, not on success.
@Suite("KeyboardState — resolved UDID reaches dispatch end-to-end", .serialized, .enabled(if: isE2EEnabled))
struct KeyboardStateRunRegressionTests {
    @Test("text path: explicit --udid reaches FBSimulatorSet (no empty-UDID surface)")
    func textPathRoutesUDID() async throws {
        let simUsePath = try TestHelpers.getSimUsePath()
        // A UDID that no FBSimulatorSet will know about. The test doesn't
        // need a booted sim — only that the resolved value flows through
        // run() → execute() → setup → SoftKeyboardDetector.
        let bogusUDID = "BOGUS-UDID-FOR-LINEIOS-216939-TEXT"
        let result = try await CommandRunner.run(
            "\"\(simUsePath)\" keyboard-state --udid \(bogusUDID)",
            allowFailure: true
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains(bogusUDID),
                "expected error to echo the explicit UDID; got: \(result.output)")
        #expect(!result.output.contains("UDID  not found"),
                "regression: empty UDID surfaced (note double space) — run() skipped resolveDeferredArguments. Output: \(result.output)")
    }

    @Test("--json path: invocation produces an envelope, not a usage error")
    func jsonPathProducesEnvelope() async throws {
        let simUsePath = try TestHelpers.getSimUsePath()
        let result = try await CommandRunner.run(
            "\"\(simUsePath)\" keyboard-state --udid BOGUS-UDID-LINEIOS-216939-JSON --json",
            allowFailure: true
        )

        #expect(result.exitCode != 0)
        // Pre-fix: the resolver-failure-before-execute path didn't run,
        // so an unbooted-host invocation died with the generic
        // "(ArgumentParser.ValidationError error 1.)" wrapper. Post-fix
        // the envelope is the structured `{"error": ..., "ok": false}`
        // shape that agents parse.
        #expect(result.output.contains("\"ok\":false"),
                "expected structured JSON envelope; got: \(result.output)")
        #expect(!result.output.contains("ArgumentParser.ValidationError"),
                "regression: ArgumentParser usage error leaked into --json envelope. Output: \(result.output)")
    }
}

// keyboard-state is a read-only AX probe with the same daemon-eligibility
// surface as describe-ui (non-nil `simulatorUDIDForDaemon`, no
// `daemonBypass`), so it must amortise init through the per-UDID daemon
// like every other verb. A vestigial `run()` override used to bypass the
// protocol default and run inline, silently opting the verb out of daemon
// routing (and the crash-advisory banner + hint formatting). This suite
// pins the restored routing: after a successful keyboard-state call a
// daemon exists for the target UDID. Requires a booted simulator
// (`SIMULATOR_UDID`).
@Suite("KeyboardState — routes through the per-UDID daemon", .serialized, .enabled(if: isE2EEnabled))
struct KeyboardStateDaemonRoutingTests {
    @Test("a successful keyboard-state call spawns/uses the per-UDID daemon")
    func routesThroughDaemon() async throws {
        let udid = try #require(defaultSimulatorUDID, "SIMULATOR_UDID must be set for this e2e test")
        let simUsePath = try TestHelpers.getSimUsePath()

        // Clean slate: no daemon for this UDID before the call.
        _ = try await CommandRunner.run(
            "\"\(simUsePath)\" daemon stop --udid \(udid)",
            allowFailure: true
        )

        // Assert the precondition explicitly. Without it a stale or
        // pre-existing daemon for this UDID (stop failed, or the box
        // already had one) would make the post-call `status` contain the
        // UDID even under the inline-execution regression — a false pass.
        // The post-call check is only meaningful if we start from empty.
        let preStatus = try await CommandRunner.run(
            "\"\(simUsePath)\" daemon status --json",
            allowFailure: true
        )
        #expect(!preStatus.output.contains(udid),
                "precondition: no daemon for \(udid) should exist before the call (stop may have failed); status: \(preStatus.output)")

        // On a freshly booted simulator the frontmost app is SpringBoard,
        // which has no software keyboard: expect a clean `hidden`, exit 0.
        let result = try await CommandRunner.run("\"\(simUsePath)\" keyboard-state --udid \(udid)")
        #expect(result.exitCode == 0)
        #expect(result.output.contains("hidden") || result.output.contains("soft"))

        // Daemon routing restored → the call spawned a daemon that is now
        // discoverable. Inline execution (the old override) would leave
        // `daemon status` empty for this UDID.
        let status = try await CommandRunner.run(
            "\"\(simUsePath)\" daemon status --json",
            allowFailure: true
        )
        #expect(status.output.contains(udid),
                "keyboard-state should have routed through a daemon for \(udid); status: \(status.output)")
    }
}