// SPDX-License-Identifier: Apache-2.0
import FBSimulatorControl
import Foundation
import SimUseCore

/// Sends hinge and orientation changes and confirms them by reading
/// CoreDevice back. The signal is the display `active` flag and the
/// display rotation, never the backlight (plan E19, E20).
public enum PostureController {
    public struct FoldOutcome: Codable, Equatable, Sendable {
        public let requested: String
        public let hingeAngle: Double
        /// True when the expected display became active. Always true for an
        /// intermediate angle, which has no expectation (plan E21).
        public let confirmed: Bool
        public let posture: PostureReport
    }

    public struct RotateOutcome: Codable, Equatable, Sendable {
        public let requested: String
        /// The device orientation sent last (device convention).
        public let deviceOrientation: String
        /// The interface orientation the routing display shows afterwards.
        public let orientation: String?
        public let confirmed: Bool
        public let posture: PostureReport?
    }

    static let pollInterval: UInt64 = 250_000_000
    /// How long a rotation read-back other than the wanted one must wait
    /// before it counts as the answer.
    static let unexpectedReportGrace: TimeInterval = 1.5

    // MARK: Fold

    public static func fold(
        udid: String,
        target: FoldTarget,
        timeout: TimeInterval,
        logger: SimUseLogger,
        topologyMonitor: SimulatorDisplayTopologyMonitor = .shared,
        sessionMonitor: ResizableAppSessionMonitor = .shared
    ) async throws -> FoldOutcome {
        let topology = try await requireTopology(udid: udid, monitor: topologyMonitor)
        guard topology.isMultiDisplay else {
            throw CLIError(errorDescription: "Simulator \(udid) has \(topology.integratedDisplays.count) integrated display; `ios fold` applies to foldable simulators such as iPhone Duo.")
        }

        let session = try await HIDInteractor.makeSession(for: udid, logger: logger)
        try await VendorDefinedHID.send(.hinge(degrees: target.degrees), to: session.simulator, logger: logger)
        OutlineCache.invalidate(udid: udid)

        let expectation = target.expectation
        let settled = await waitForTopology(udid: udid, timeout: timeout, monitor: topologyMonitor) { previous, current in
            guard expectation.isMet(by: current) else { return false }
            // Without an expectation, wait for two equal reads so a
            // display switch still in flight is not reported.
            if expectation == .observeOnly {
                return previous?.activeIntegrated?.uniqueID == current.activeIntegrated?.uniqueID
            }
            return true
        }
        let final = settled.topology ?? topology
        let confirmed = settled.met
        let sessionState = await postureChanged(udid: udid, topologyMonitor: topologyMonitor, sessionMonitor: sessionMonitor)
        let outcome = FoldOutcome(
            requested: target.description,
            hingeAngle: target.degrees,
            confirmed: confirmed,
            posture: PostureReport(topology: final, session: sessionState)
        )
        guard confirmed else {
            let expected = expectation == .primaryActive ? "the primary display" : "a non-primary integrated display"
            throw CLIError(errorDescription: "Sent hinge \(ResizableAppSession.format(target.degrees))° to simulator \(udid), but \(expected) did not become active within \(ResizableAppSession.format(timeout)) s (\(outcome.posture.summary)).")
        }
        return outcome
    }

    // MARK: Rotate

    public static func rotate(
        udid: String,
        target: DisplayOrientation,
        timeout: TimeInterval,
        logger: SimUseLogger,
        topologyMonitor: SimulatorDisplayTopologyMonitor = .shared,
        sessionMonitor: ResizableAppSessionMonitor = .shared
    ) async throws -> (outcome: RotateOutcome, advisory: CommandAdvisory?) {
        try await assertNoResizeSession(udid: udid, sessionMonitor: sessionMonitor)

        let before = await topologyMonitor.state(for: udid, fresh: true).topology
        let session = try await HIDInteractor.makeSession(for: udid, logger: logger)
        let multiDisplay = before?.isMultiDisplay ?? false
        let display = before.flatMap { $0.activeIntegrated ?? $0.primary }

        let wanted = RotationPlanner.deviceOrientation(for: target)
        var offset = RotationPlanner.initialTransportOffset(display: multiDisplay ? display : nil)
        var sent = RotationPlanner.sendValue(for: wanted, transportOffset: offset)
        try await send(sent, multiDisplay: multiDisplay, session: session, logger: logger)
        OutlineCache.invalidate(udid: udid)

        var after = await waitForRotation(udid: udid, wanted: wanted, timeout: timeout, monitor: topologyMonitor)
        // The transport offset of a secondary display is a guess. When the
        // device turned, but to the wrong side, the read-back gives the
        // real offset and one corrected send lands. A report that did not
        // change at all teaches nothing: the frontmost app or the display
        // does not accept the orientation (an iPhone-size screen refuses
        // portrait-upside-down; a portrait-only app keeps portrait).
        if let reported = after?.deviceOrientation, reported != wanted.rawValue,
           reported != before?.deviceOrientation,
           let learned = RotationPlanner.learnedTransportOffset(sent: sent, reported: reported), learned != offset
        {
            logger.info().log("Orientation report \(sent.rawValue) read back as \(reported); correcting the transport offset from \(offset) to \(learned)")
            offset = learned
            sent = RotationPlanner.sendValue(for: wanted, transportOffset: offset)
            try await send(sent, multiDisplay: multiDisplay, session: session, logger: logger)
            after = await waitForRotation(udid: udid, wanted: wanted, timeout: timeout, monitor: topologyMonitor)
        }
        _ = await postureChanged(udid: udid, topologyMonitor: topologyMonitor, sessionMonitor: sessionMonitor)

        guard let after else {
            // No CoreDevice read-back (older devicectl): the change was
            // sent but cannot be confirmed.
            let outcome = RotateOutcome(requested: target.rawValue, deviceOrientation: wanted.rawValue, orientation: nil, confirmed: false, posture: nil)
            return (outcome, CommandAdvisory(
                kind: .orientationCalibrationFallback,
                message: "Sent device orientation \(wanted.rawValue), but CoreDevice could not report the result on this Xcode; run `describe-ui` to see the interface orientation."
            ))
        }

        let reached = (after.activeIntegrated ?? after.primary)?.rotation.interfaceOrientation
        let outcome = RotateOutcome(
            requested: target.rawValue,
            deviceOrientation: wanted.rawValue,
            orientation: reached?.rawValue,
            confirmed: reached == target,
            posture: PostureReport(topology: after, session: nil)
        )
        guard reached == target else {
            return (outcome, CommandAdvisory(
                kind: .orientationCalibrationFallback,
                message: "The interface stayed \(reached?.rawValue ?? "unknown"): the frontmost app or the display does not accept \(target.rawValue) " +
                    "(for example a portrait-only app, SpringBoard on iPhone, or portrait-upside-down on an iPhone-size screen). " +
                    "CoreDevice reports device orientation \(after.deviceOrientation ?? "unknown")."
            ))
        }
        return (outcome, nil)
    }

    /// Single-display simulators rotate through the Purple GSEvent path
    /// that the HID connection already carries; a multi-display simulator
    /// only reacts to the orientation picker report (plan E10–E13), the
    /// same split upstream idb makes on "runtime reports device motion".
    static func send(
        _ orientation: DeviceOrientationValue,
        multiDisplay: Bool,
        session: HIDInteractor.Session,
        logger: SimUseLogger
    ) async throws {
        if multiDisplay {
            try await VendorDefinedHID.send(.orientation(orientation.virtualMachineValue), to: session.simulator, logger: logger)
        } else {
            try await HIDInteractor.performHIDEvent(.deviceOrientation(orientation.purpleOrientation), in: session, logger: logger)
        }
    }

    // MARK: Cached state

    /// After a fold or a rotation: the routing state the daemon caches is
    /// stale (unfolding ends a Resize Mode session, R157-01). Returns the
    /// session state now.
    static func postureChanged(
        udid: String,
        topologyMonitor: SimulatorDisplayTopologyMonitor,
        sessionMonitor: ResizableAppSessionMonitor
    ) async -> ResizableAppSession? {
        await topologyMonitor.invalidate(udid: udid)
        await sessionMonitor.invalidate(udid: udid)
        return await sessionMonitor.state(for: udid).session
    }

    /// Resize Mode sessions are portrait-only. Checked against CoreDevice,
    /// not the cache: a fold or another tool may have ended the session
    /// inside the cache window.
    static func assertNoResizeSession(udid: String, sessionMonitor: ResizableAppSessionMonitor) async throws {
        await sessionMonitor.invalidate(udid: udid)
        if case .active(let resizable) = await sessionMonitor.state(for: udid) {
            throw CLIError(errorDescription: "A resizable app session (Xcode 27 Resize Mode, \(resizable.preferredSizeDescription)) is active on simulator \(udid). Sessions are portrait-only; end the session before rotating.")
        }
    }

    // MARK: Polling

    static func requireTopology(udid: String, monitor: SimulatorDisplayTopologyMonitor) async throws -> SimulatorDisplayTopology {
        switch await monitor.state(for: udid, fresh: true) {
        case .available(let topology):
            return topology
        case .unavailable(let reason):
            throw CLIError(errorDescription: "Could not read the displays of simulator \(udid) from CoreDevice (\(reason)). `ios fold` needs `xcrun devicectl` from Xcode 26.6 or later.")
        }
    }

    static func waitForTopology(
        udid: String,
        timeout: TimeInterval,
        monitor: SimulatorDisplayTopologyMonitor,
        isSettled: (SimulatorDisplayTopology?, SimulatorDisplayTopology) -> Bool
    ) async -> (topology: SimulatorDisplayTopology?, met: Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: SimulatorDisplayTopology?
        var last: SimulatorDisplayTopology?
        repeat {
            if let topology = await monitor.state(for: udid, fresh: true).topology {
                if isSettled(previous, topology) { return (topology, true) }
                previous = topology
                last = topology
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        } while Date() < deadline
        return (last, false)
    }

    /// Waits for the device to report `wanted` and the active display's
    /// rotation to hold for two reads. Returns the last read when the
    /// device settles elsewhere (so the caller can learn from it), nil when
    /// CoreDevice cannot answer.
    static func waitForRotation(
        udid: String,
        wanted: DeviceOrientationValue,
        timeout: TimeInterval,
        monitor: SimulatorDisplayTopologyMonitor
    ) async -> SimulatorDisplayTopology? {
        let start = Date()
        let result = await waitForTopology(udid: udid, timeout: timeout, monitor: monitor) { previous, current in
            // Settled when two reads agree on the reported orientation and
            // on the rotation. A report other than `wanted` that holds is
            // an answer too — a wrong transport offset, or a device that
            // refused — but only after `unexpectedReportGrace`, because the
            // first reads can still show the orientation from before.
            guard let previous, let reported = current.deviceOrientation,
                  previous.deviceOrientation == reported,
                  (previous.activeIntegrated ?? previous.primary)?.rotation == (current.activeIntegrated ?? current.primary)?.rotation
            else { return false }
            return reported == wanted.rawValue || Date().timeIntervalSince(start) >= unexpectedReportGrace
        }
        return result.topology
    }
}

extension DeviceOrientationValue {
    /// The Purple GSEvent value for this device orientation. Purple numbers
    /// landscape in interface style, so device left and right swap
    /// (upstream idb `physicalPurpleOrientation`).
    var purpleOrientation: FBSimulatorHIDDeviceOrientation {
        switch self {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        }
    }
}
