// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBControlCore
import FBSimulatorControl
import SimUseCore

// MARK: - HID Interactor
@MainActor
public struct HIDInteractor {

    public struct Session {
        public let simulatorUDID: String
        public let simulator: FBSimulator
        public let hid: FBSimulatorHID
    }

    // Cache for HID connections per simulator
    private static var hidConnections: [String: FBSimulatorHID] = [:]

    /// Configurable stabilization delay to ensure HID events are fully processed
    /// Can be set via SIM_USE_HID_STABILIZATION_MS environment variable
    private static var stabilizationDelayMs: UInt64 {
        if let envValue = ProcessInfo.processInfo.environment["SIM_USE_HID_STABILIZATION_MS"],
           let milliseconds = UInt64(envValue) {
            return min(milliseconds, 1000)
        }
        return 25
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
        logger.info().log("Performing HID event...")
        let eventFuture = event.perform(on: session.hid)
        _ = try await FutureBridge.value(eventFuture)
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
        if let existingHID = hidConnections[simulator.udid] {
            logger.info().log("Using existing HID connection for simulator \(simulator.udid)")
            return existingHID
        }

        logger.info().log("Creating new HID connection for simulator \(simulator.udid)...")
        let hidFuture = simulator.connectToHID()
        let hid = try await FutureBridge.value(hidFuture)

        hidConnections[simulator.udid] = hid
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