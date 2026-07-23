// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBControlCore
import FBSimulatorControl
import SimUseCore

// MARK: - HID Interactor
@MainActor
public struct HIDInteractor {

    /// A HID session against one simulator boot. Commands that hold a
    /// Session across many events (type, batch, gesture) do not re-check
    /// boot identity per event: a mid-burst reboot fails the burst —
    /// loudly, via the send deadline — and the next command recovers
    /// through the boot gate in `getOrCreateHIDConnection`.
    public struct Session {
        public let simulatorUDID: String
        public let simulator: FBSimulator
        public let hid: FBSimulatorHID
    }

    // Cache for HID connections per simulator. Each entry carries the
    // boot token it was created against (see HIDBootIdentity): the
    // connection's mach port dies with that boot, and a send through a
    // dead port hangs or silently drops input (issue #55), so reuse
    // must be gated on the token before anything is sent.
    private struct CachedConnection {
        let hid: FBSimulatorHID
        let bootToken: HIDBootToken
    }

    private static var hidConnections: [String: CachedConnection] = [:]

    /// Configurable stabilization delay to ensure HID events are fully processed
    /// Can be set via SIM_USE_HID_STABILIZATION_MS environment variable
    private static var stabilizationDelayMs: UInt64 {
        if let envValue = ProcessInfo.processInfo.environment["SIM_USE_HID_STABILIZATION_MS"],
           let milliseconds = UInt64(envValue) {
            return min(milliseconds, 1000)
        }
        return 25
    }

    /// Deadline for a single HID send (see HIDSendDeadline). A single
    /// perform can legitimately run ~10 s (swipe/press durations), so
    /// the default leaves generous headroom. Override via
    /// SIM_USE_HID_SEND_TIMEOUT_MS; 0 disables the deadline.
    private static var sendTimeoutMs: UInt64 {
        if let envValue = ProcessInfo.processInfo.environment["SIM_USE_HID_SEND_TIMEOUT_MS"],
           let milliseconds = UInt64(envValue) {
            return milliseconds
        }
        return 30_000
    }

    public static func makeSession(for simulatorUDID: String, logger: SimUseLogger) async throws -> Session {
        logger.info().log("Loading private frameworks for HID operations...")
        let frameworkLoader = FBSimulatorControlFrameworkLoader.xcodeFrameworks
        // Xcode 27 removed SimulatorKit; surface an actionable message
        // (select Xcode 26.x) before the loader fails cryptically.
        try XcodeCompatibility.assertSimulatorKitAvailable(logger: logger)
        do {
            try frameworkLoader.loadPrivateFrameworks(logger)
            logger.info().log("Private frameworks loaded successfully.")
        } catch {
            logger.error().log("Failed to load private frameworks: \(error)")
            throw CLIError(errorDescription: "SimulatorKit is required for HID interactions. Error: \(error)")
        }

        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        logger.info().log("FBSimulatorSet obtained.")

        guard let simulator = simulatorSet.allSimulators.first(where: { $0.udid == simulatorUDID }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(simulatorUDID) not found in set.")
        }

        logger.info().log("Target (FBSimulator) obtained: \(simulator.udid)")
        logger.info().log("Simulator name: \(simulator.name)")

        guard simulator.state == .booted else {
            throw CLIError(errorDescription: "Simulator with UDID \(simulatorUDID) is not booted. Current state: \(simulator.state)")
        }
        logger.info().log("Simulator state verified: booted")

        let hid = try await getOrCreateHIDConnection(for: simulator, logger: logger)
        return Session(simulatorUDID: simulatorUDID, simulator: simulator, hid: hid)
    }

    public static func performHIDEvent(_ event: FBSimulatorHIDEvent, in session: Session, logger: SimUseLogger) async throws {
        do {
            try await performHIDEventOnce(event, in: session, logger: logger)
        } catch {
            // Fail-invalidate + cautious retry-once: see HIDPerformRecovery
            // for the decision rules and why only dead-transport errors
            // are safe to re-perform.
            try await HIDPerformRecovery.recover(from: error, invalidate: {
                logger.error().log("HID event failed (\(error.localizedDescription)); dropping cached HID connection for \(session.simulatorUDID)")
                clearHIDConnection(for: session.simulatorUDID)
            }, rebuildAndRetry: {
                logger.info().log("Dead HID transport for \(session.simulatorUDID); rebuilding session and retrying once...")
                let freshSession = try await makeSession(for: session.simulatorUDID, logger: logger)
                do {
                    try await performHIDEventOnce(event, in: freshSession, logger: logger)
                } catch {
                    // Keep the "a failed perform never leaves its
                    // connection cached" invariant on the retry path too.
                    clearHIDConnection(for: session.simulatorUDID)
                    throw error
                }
            })
        }
    }

    private static func performHIDEventOnce(_ event: FBSimulatorHIDEvent, in session: Session, logger: SimUseLogger) async throws {
        logger.info().log("Performing HID event...")
        let eventFuture = event.perform(on: session.hid)
        let timeoutMs = sendTimeoutMs
        if timeoutMs > 0 {
            let udid = session.simulatorUDID
            try await HIDSendDeadline.run(milliseconds: timeoutMs) {
                try await FutureBridge.value(eventFuture)
            } onTimeout: {
                CLIError(errorDescription: """
                HID event delivery timed out after \(timeoutMs) ms; the connection to \
                simulator \(udid) may be dead (rebooted mid-command?). The cached \
                connection is dropped and rebuilt on the next command.
                """)
            }
        } else {
            _ = try await FutureBridge.value(eventFuture)
        }
        logger.info().log("HID event performed successfully.")

        if stabilizationDelayMs > 0 {
            logger.info().log("Applying stabilization delay of \(stabilizationDelayMs)ms...")
            try await Task.sleep(nanoseconds: stabilizationDelayMs * 1_000_000)
        }
    }

    public static func performHIDEvent(_ event: FBSimulatorHIDEvent, for simulatorUDID: String, logger: SimUseLogger) async throws {
        let session = try await makeSession(for: simulatorUDID, logger: logger)
        try await performHIDEvent(event, in: session, logger: logger)
    }

    // Get or create a cached HID connection (matching CompanionLib's connectToHID behavior)
    private static func getOrCreateHIDConnection(for simulator: FBSimulator, logger: SimUseLogger) async throws -> FBSimulatorHID {
        let currentToken = HIDBootIdentity.token(dataDirectory: simulator.dataDirectory, udid: simulator.udid)
        if let cached = hidConnections[simulator.udid] {
            if HIDBootIdentity.isReusable(cachedToken: cached.bootToken, currentToken: currentToken) {
                logger.info().log("Using existing HID connection for simulator \(simulator.udid)")
                return cached.hid
            }
            // The simulator was re-booted (or the boot identity is
            // unknowable) since the connection was made: the cached
            // handle's mach port is dead and must not be sent through.
            logger.info().log("Boot identity changed for simulator \(simulator.udid) (cached: \(cached.bootToken); current: \(currentToken)); discarding cached HID connection")
            hidConnections.removeValue(forKey: simulator.udid)
        }

        logger.info().log("Creating new HID connection for simulator \(simulator.udid)...")
        let hidFuture = simulator.connectToHID()
        let hid = try await FutureBridge.value(hidFuture)

        hidConnections[simulator.udid] = CachedConnection(hid: hid, bootToken: currentToken)
        logger.info().log("HID connection created and cached for simulator \(simulator.udid)")

        return hid
    }

    public static func clearHIDConnections() {
        hidConnections.removeAll()
    }

    /// Drop the cached HID connection for a single UDID. Used by
    /// daemon stale-simulator detection (LINEIOS-216942): once the
    /// daemon proves the simulator was shut down out of band, the
    /// cached `FBSimulatorHID` handle is dead and must not be reused
    /// even if the same UDID is re-booted before the daemon process
    /// itself terminates.
    public static func clearHIDConnection(for simulatorUDID: String) {
        hidConnections.removeValue(forKey: simulatorUDID)
    }
} 