// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

// Coverage for the rebooted-simulator HID cache poisoning fix: a
// simulator shut down and re-booted under the same UDID passes
// `makeSession`'s `state == .booted` re-check, so the daemon reuses
// the cached `FBSimulatorHID` whose mach port belongs to the previous
// boot. The resulting perform failure did not match
// `DaemonErrorKind.isStaleSimulatorMessage`, so the stale cleanup
// never fired and the UDID stayed broken until daemon restart.
//
// The fix is fail-invalidate + cautious retry-once, decided by
// `HIDPerformRecovery`. FB* types cannot be constructed in unit
// tests, so the decision logic is a pure classifier over the error
// message and the orchestration takes injected closures; these tests
// cover both. `HIDInteractor.performHIDEvent` wires the closures to
// `clearHIDConnection(for:)` and a `makeSession` rebuild.

// MARK: - Fixtures

private struct MessageError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { self.errorDescription = message }
}

// MARK: - Classification rules

@Suite("HIDPerformRecovery.classify")
struct HIDPerformRecoveryClassifyTests {

    // Dead-transport errors: the kernel refused (or could not accept)
    // the Indigo message, so nothing reached the currently-booted
    // simulator instance. Rebuilding the session and re-performing
    // cannot double-apply the event.

    @Test("SimulatorKit MACH_SEND_INVALID_DEST wording maps to invalidateAndRetry")
    func machPortInvalid() {
        // SimDeviceLegacyHIDClient.HIDError when mach_msg_send returns
        // MACH_SEND_INVALID_DEST — the exact signature of a cached HID
        // handle whose port died with the previous boot.
        let error = MessageError("Mach port invalid, device disconnected")
        #expect(HIDPerformRecovery.classify(error) == .invalidateAndRetry)
    }

    @Test("SimulatorKit nil-port wording maps to invalidateAndRetry")
    func machPortNotConnected() {
        // SimDeviceLegacyHIDClient.HIDError when the client never
        // obtained a legacy HID event port: no event was ever sent
        // through this client.
        let error = MessageError("Mach port not connected, device may not be ready yet")
        #expect(HIDPerformRecovery.classify(error) == .invalidateAndRetry)
    }

    @Test("FBSimulatorControl disposed-client wording maps to invalidateAndRetry")
    func disposedClient() {
        // FBSimulatorHID.connect after disconnect; emitted before any
        // send, so a retry is safe by construction.
        let error = MessageError("Cannot Connect, HID client has already been disposed of")
        #expect(HIDPerformRecovery.classify(error) == .invalidateAndRetry)
    }

    @Test("mach_error_string wording for a dead destination maps to invalidateAndRetry")
    func machErrorString() {
        // Defensive: some wrappers render kern_return_t via
        // mach_error_string, which yields this text for
        // MACH_SEND_INVALID_DEST.
        let error = MessageError("(ipc/send) invalid destination port")
        #expect(HIDPerformRecovery.classify(error) == .invalidateAndRetry)
    }

    @Test("Substring match is enough; surrounding text is fine")
    func substringMatch() {
        let error = MessageError("Error Domain=... {Mach port invalid, device disconnected}")
        #expect(HIDPerformRecovery.classify(error) == .invalidateAndRetry)
    }

    // Everything else: the transport may have been alive when earlier
    // sub-events of a composite gesture were delivered, so a blind
    // re-perform could double-apply them. Invalidate only.

    @Test("Generic mach send failures map to invalidateOnly")
    func genericMachReturn() {
        // SimulatorKit renders every kern_return_t other than
        // MACH_SEND_INVALID_DEST as "Mach return error <code>"; e.g. a
        // send timeout can hit an event in the middle of a composite
        // gesture whose earlier touches were already delivered.
        let error = MessageError("Mach return error 268435460")
        #expect(HIDPerformRecovery.classify(error) == .invalidateOnly)
    }

    @Test("Semantic HID failures map to invalidateOnly")
    func semanticFailures() {
        #expect(HIDPerformRecovery.classify(
            MessageError("MessageForMouseNSEvent returned nil for multi-touch event")) == .invalidateOnly)
        #expect(HIDPerformRecovery.classify(
            MessageError("Failed to allocate IndigoHIDMessage")) == .invalidateOnly)
    }

    @Test("Unrelated and empty messages map to invalidateOnly")
    func unrelatedFallsBack() {
        #expect(HIDPerformRecovery.classify(MessageError("Something else entirely")) == .invalidateOnly)
        #expect(HIDPerformRecovery.classify(MessageError("")) == .invalidateOnly)
    }
}

// MARK: - Recovery orchestration

@Suite("HIDPerformRecovery.recover")
@MainActor
struct HIDPerformRecoveryRecoverTests {

    @Test("Dead-transport failure invalidates, then retries once; success is swallowed")
    func deadTransportRetries() async throws {
        var calls: [String] = []
        try await HIDPerformRecovery.recover(
            from: MessageError("Mach port invalid, device disconnected"),
            invalidate: { calls.append("invalidate") },
            rebuildAndRetry: { calls.append("retry") }
        )
        // Invalidation must precede the retry: the rebuild path goes
        // through the connection cache and must not see the dead entry.
        #expect(calls == ["invalidate", "retry"])
    }

    @Test("Non-retryable failure invalidates and rethrows the original error; no retry")
    func otherInvalidatesOnly() async {
        var calls: [String] = []
        let original = MessageError("Mach return error 268435460")
        await #expect {
            try await HIDPerformRecovery.recover(
                from: original,
                invalidate: { calls.append("invalidate") },
                rebuildAndRetry: { calls.append("retry") }
            )
        } throws: { error in
            error.localizedDescription == original.localizedDescription
        }
        #expect(calls == ["invalidate"])
    }

    @Test("A failing retry propagates the retry error, not the original")
    func retryFailurePropagates() async {
        // The fresher error matters downstream: if the simulator went
        // away between invalidation and the retry, the rebuild fails
        // with "not found in set" / "is not booted. Current state",
        // which the daemon classifies as staleSimulator and uses to
        // self-terminate.
        var calls: [String] = []
        await #expect {
            try await HIDPerformRecovery.recover(
                from: MessageError("Mach port invalid, device disconnected"),
                invalidate: { calls.append("invalidate") },
                rebuildAndRetry: {
                    calls.append("retry")
                    throw MessageError("Simulator with UDID ABCD is not booted. Current state: 1")
                }
            )
        } throws: { error in
            error.localizedDescription.contains("is not booted. Current state")
        }
        #expect(calls == ["invalidate", "retry"])
    }
}
