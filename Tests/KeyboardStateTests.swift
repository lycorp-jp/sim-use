// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import ArgumentParser
import Foundation
import Testing
@testable import SimUseCore

// Regression coverage for LINEIOS-216939: KeyboardState overrides `run()`
// (so the text path can return exit 1 when the keyboard is hidden), but
// the override has to call `resolveDeferredArguments()` itself — the
// protocol-default `run()` is what wires that for every other command.
// Without the explicit call, `udid.resolved` stays "" and every dispatch
// fails with `"Simulator with UDID  not found in set."` (note the double
// space — the empty UDID).

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

// End-to-end coverage that catches the actual run()-bypasses-resolve
// regression. Doesn't require a booted simulator — the test just asserts
// that the explicit UDID echoes back inside the "not found in set"
// error. Pre-fix the message contained an empty UDID (`UDID  not
// found`); post-fix it contains BOGUS-UDID-* (or whatever was passed).
//
// Only the text path can carry the UDID assertion: the `--json` error
// envelope currently goes through `error.localizedDescription`, which
// for our `CLIError` reports the NSError-bridged generic message
// instead of the typed `errorDescription` payload. That's a separate
// concern; this suite stays narrow to the resolveDeferredArguments
// regression.
@Suite("KeyboardState — run() wires resolveDeferredArguments end-to-end", .serialized, .enabled(if: isE2EEnabled))
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