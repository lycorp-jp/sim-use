// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Recovery decision for a failed `FBSimulatorHIDEvent` perform.
///
/// A simulator that is shut down and re-booted under the same UDID
/// passes `makeSession`'s `state == .booted` re-check, so the cached
/// `FBSimulatorHID` — whose mach port belongs to the previous boot —
/// is handed back and every perform fails. The daemon's stale-simulator
/// cleanup never fires for these failures (the message doesn't match
/// `DaemonErrorKind.isStaleSimulatorMessage`), which used to poison the
/// UDID until the daemon restarted.
///
/// Every perform failure therefore invalidates the cached connection:
/// that is cheap and safe, because the next command rebuilds it. The
/// retry decision is stricter. `FBSimulatorHIDEvent` composites (tap,
/// swipe, type) deliver one mach message per sub-event and short-circuit
/// on the first failure, so a blind re-perform could double-apply
/// sub-events that were already delivered. Retry is gated on
/// dead-transport errors only, where delivery to the currently-booted
/// simulator instance provably never happened:
///
/// - `mach_msg_send` returning `MACH_SEND_INVALID_DEST` means the kernel
///   refused the message — the port died with the previous boot and the
///   failing sub-event reached nothing. Earlier sub-events of the same
///   composite either failed the same way (port dead from the start,
///   the reboot-window case) or were delivered to the *previous* boot,
///   which is gone; re-performing against the current boot cannot
///   double-apply on any live UI. SimulatorKit's
///   `SimDeviceLegacyHIDClient.HIDError` renders this case as
///   "Mach port invalid, device disconnected" (verified against the
///   Xcode 26.x binary).
/// - A client that never obtained its HID event port renders as
///   "Mach port not connected, device may not be ready yet"; nothing
///   was ever sent through it.
/// - FBSimulatorControl's own "Cannot Connect, HID client has already
///   been disposed of" is emitted before any send by construction.
///
/// Every other message — including SimulatorKit's generic
/// "Mach return error <code>" (e.g. a send timeout that can hit the
/// middle of a composite while earlier touches were delivered) — gets
/// `invalidateOnly`: the current command fails, the next one self-heals
/// against a fresh connection.
public enum HIDPerformRecovery: Equatable {
    case invalidateAndRetry
    case invalidateOnly

    /// Message fragments that prove the failing event never reached the
    /// currently-booted simulator instance. Sources: SimulatorKit's
    /// `SimDeviceLegacyHIDClient.HIDError` descriptions,
    /// FBSimulatorControl's `FBSimulatorHID.connect`, and
    /// `mach_error_string(MACH_SEND_INVALID_DEST)` for wrappers that
    /// render the raw kern_return_t.
    private static let deadTransportMarkers = [
        "Mach port invalid",
        "Mach port not connected",
        "has already been disposed",
        "invalid destination port",
    ]

    public static func classify(_ error: Error) -> HIDPerformRecovery {
        classify(message: error.localizedDescription)
    }

    public static func classify(message: String) -> HIDPerformRecovery {
        for marker in deadTransportMarkers where message.contains(marker) {
            return .invalidateAndRetry
        }
        return .invalidateOnly
    }

    /// Applies the recovery decision for a failed perform. `invalidate`
    /// always runs first so the rebuild path cannot observe the dead
    /// cache entry; `rebuildAndRetry` runs at most once and its error —
    /// fresher than the original (e.g. "is not booted. Current state"
    /// when the simulator went away for good, which the daemon
    /// classifies as stale) — is the one propagated.
    ///
    /// Injected closures keep the FB* types out of unit tests;
    /// `HIDInteractor.performHIDEvent` binds them to
    /// `clearHIDConnection(for:)` and a `makeSession` rebuild.
    @MainActor
    public static func recover(
        from error: Error,
        invalidate: () -> Void,
        rebuildAndRetry: () async throws -> Void
    ) async throws {
        invalidate()
        guard classify(error) == .invalidateAndRetry else {
            throw error
        }
        try await rebuildAndRetry()
    }
}
