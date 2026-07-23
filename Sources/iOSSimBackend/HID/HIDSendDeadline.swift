// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Bounded wait for a HID send.
///
/// A send through a dead HID mach port can hang forever on current
/// SimulatorKit (observed live on Xcode 26.5 / iOS 26.2): the perform's
/// completion never fires, no error reaches
/// `HIDPerformRecovery.classify`, and the daemon wedges mid-request
/// until it is killed. The boot-identity gate prevents that for reboots
/// that happen *between* commands; this deadline covers the residual
/// window — a reboot mid-command, or a boot-identity signal failing in
/// a way not yet seen — by turning the hang into a loud error.
///
/// The timeout error's text must match none of
/// `HIDPerformRecovery.deadTransportMarkers` (pinned by a unit test):
/// a timed-out composite may have delivered some sub-events, so
/// recovery must stay `invalidateOnly` — fail the command, rebuild on
/// the next one — never a blind retry.
enum HIDSendDeadline {

    /// Races `operation` against a deadline. Losing the race cancels
    /// the operation's task; `FutureBridge.value` forwards that
    /// cancellation to the underlying `FBFuture`.
    static func run<T: Sendable>(
        milliseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T,
        onTimeout makeTimeoutError: @escaping @Sendable () -> Error
    ) async throws -> T {
        // Saturate instead of trapping on the ms→ns conversion: any
        // parseable SIM_USE_HID_SEND_TIMEOUT_MS reaches this multiply,
        // and an absurdly large value means "effectively no deadline"
        // (UInt64.max ns ≈ 584 years), not a crash.
        let (nanoseconds, overflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: overflow ? .max : nanoseconds)
                throw makeTimeoutError()
            }
            defer { group.cancelAll() }
            // next() is nil only for an empty group; both children are
            // always added above.
            guard let winner = try await group.next() else {
                throw makeTimeoutError()
            }
            return winner
        }
    }
}
