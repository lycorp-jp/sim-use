// SPDX-License-Identifier: Apache-2.0
import Foundation
import CompanionUtilities
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
        /// Shared by every copy of the session: when a routed touch moves
        /// the session to the DTUHID transport, or a dead transport is
        /// rebuilt, a caller holding the session across events (batch,
        /// type, multi-touch) sends the next event on the new connection,
        /// not on the one that was disconnected (review S6-001).
        let connection: Connection

        public var hid: FBSimulatorHID { connection.hid }
        /// The transport the connection uses, when known (forced, or the
        /// auto-selection's dtuhidd signal at creation).
        public var transport: FBSimulatorHIDTransportType? { connection.transport }
    }

    final class Connection {
        var hid: FBSimulatorHID
        var transport: FBSimulatorHIDTransportType?

        init(hid: FBSimulatorHID, transport: FBSimulatorHIDTransportType?) {
            self.hid = hid
            self.transport = transport
        }

        func adopt(_ other: Connection) {
            hid = other.hid
            transport = other.transport
        }
    }

    // Cache for HID connections per simulator. Each entry carries the
    // boot token it was created against (see HIDBootIdentity): the
    // connection's mach port dies with that boot, and a send through a
    // dead port hangs or silently drops input (issue #55), so reuse
    // must be gated on the token before anything is sent.
    // `transportTrusted` is false when the transport was auto-selected
    // inside the boot-attach trust window (issue #67): the entry may
    // serve the command that created it but must not be reused, so the
    // next command re-derives the selection.
    private struct CachedConnection {
        let hid: FBSimulatorHID
        let bootToken: HIDBootToken
        let transportTrusted: Bool
        let transport: FBSimulatorHIDTransportType?
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

    /// Debug override for the HID transport, via SIM_USE_HID_TRANSPORT
    /// (`indigo` | `dtuhid`). Unset (the default) lets upstream's
    /// auto-selection pick: the DTUHID transport on simulators whose
    /// legacy HID is dtuhidd-suppressed (booted with Device Hub open),
    /// the legacy Indigo path otherwise. Note the daemon keeps the
    /// environment it was spawned with — combine with SIM_USE_NO_DAEMON=1
    /// or a daemon restart for ad-hoc experiments.
    private static var transportOverride: FBSimulatorHIDTransportType? {
        switch ProcessInfo.processInfo.environment["SIM_USE_HID_TRANSPORT"]?.lowercased() {
        case "indigo": return .indigo
        case "dtuhid": return .dtuhid
        default: return nil
        }
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

        let (hid, transport) = try await getOrCreateHIDConnection(for: simulator, logger: logger)
        return Session(simulatorUDID: simulatorUDID, simulator: simulator, connection: Connection(hid: hid, transport: transport))
    }

    public static func performHIDEvent(_ event: FBSimulatorHIDEvent, in session: Session, logger: SimUseLogger) async throws {
        if event.containsTouch {
            try await reachRoute(with: session, logger: logger)
        }
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
                // Later events of the caller's session use the rebuilt
                // connection too.
                session.connection.adopt(freshSession.connection)
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
        try await routeTouches(of: event, in: session, logger: logger)
        let timeoutMs = sendTimeoutMs
        // Capture the hid handle, not the whole Session: FBSimulatorHID is
        // @unchecked Sendable upstream, while Session carries the
        // non-Sendable FBSimulator and would trip strict-concurrency
        // checking inside the @Sendable deadline closure.
        let hid = session.hid
        if timeoutMs > 0 {
            let udid = session.simulatorUDID
            try await HIDSendDeadline.run(milliseconds: timeoutMs) {
                try await hid.send(event: event, logger: logger)
            } onTimeout: {
                CLIError(errorDescription: """
                HID event delivery timed out after \(timeoutMs) ms; the connection to \
                simulator \(udid) may be dead (rebooted mid-command?). The cached \
                connection is dropped and rebuilt on the next command.
                """)
            }
        } else {
            try await session.hid.send(event: event, logger: logger)
        }
        logger.info().log("HID event performed successfully.")

        if stabilizationDelayMs > 0 {
            logger.info().log("Applying stabilization delay of \(stabilizationDelayMs)ms...")
            try await Task.sleep(nanoseconds: stabilizationDelayMs * 1_000_000)
        }
    }

    /// Points the connection's touch input at the display that hosts the
    /// app (an unfolded iPhone Duo's inner display, a Resize Mode session),
    /// or back at the main display. Resolved per event from the daemon's
    /// cached routing state; keyboard and button events are device-wide
    /// and skip it. Work record: docs/ai/010-display-routing/000-plan.md.
    static func routeTouches(of event: FBSimulatorHIDEvent, in session: Session, logger: SimUseLogger) async throws {
        guard event.containsTouch else { return }
        let routing = await RoutingDisplayResolver.current(udid: session.simulatorUDID)
        let route = try routing.hidRoute()
        if route != session.hid.displayRoute {
            logger.info().log("Touch input routed to \(routing.displayName.map { "display \($0) (digitizer target \(route?.digitizerTarget ?? 0))" } ?? "the main display")")
        }
        session.hid.displayRoute = route
    }

    /// Touch input for a display other than the main one needs the DTUHID
    /// transport. A simulator booted with Device Hub closed has no dtuhidd,
    /// so its connection is Indigo: start dtuhidd through its XPC service —
    /// launchd starts it on demand, as for fold — and rebuild the
    /// connection, which then selects DTUHID (docs/ai/010-display-routing, S6).
    private static func reachRoute(with session: Session, logger: SimUseLogger) async throws {
        let routing = await RoutingDisplayResolver.current(udid: session.simulatorUDID)
        let route = try routing.hidRoute()
        guard transportOverride == nil, routeNeedsDTUHID(route: route, transport: session.transport) else { return }
        let target = routing.displayName.map { "display '\($0)'" } ?? "the routed display"
        logger.info().log("Touch input for \(target) needs the DTUHID transport; starting dtuhidd in \(session.simulatorUDID)")
        try await VendorDefinedHID.startDtuhidd(on: session.simulator, logger: logger)
        var present = false
        for _ in 0..<30 {
            if dtuhiddPresenceHint(forUDID: session.simulatorUDID) == true { present = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard present else {
            throw CLIError(errorDescription: "Touch input for \(target) of simulator \(session.simulatorUDID) needs dtuhidd (the DTUHID transport), and it did not start. Open the simulator in Device Hub (Xcode 27) and try again.")
        }
        clearHIDConnection(for: session.simulatorUDID)
        let fresh = try await makeSession(for: session.simulatorUDID, logger: logger)
        session.connection.adopt(fresh.connection)
    }

    /// Whether `transport` cannot carry touch input to `route`: only the
    /// DTUHID transport reaches a digitizer other than the main display's.
    nonisolated static func routeNeedsDTUHID(route: FBSimulatorHIDDisplayRoute?, transport: FBSimulatorHIDTransportType?) -> Bool {
        route != nil && transport == .indigo
    }

    /// Whether a cached connection must be rebuilt because dtuhidd started
    /// after it was made. An active dtuhidd suppresses the legacy keyboard
    /// service, so an auto-selected Indigo connection would drop typed text
    /// silently; fold and rotate start dtuhidd when Device Hub is closed.
    nonisolated static func transportOutdated(selected: FBSimulatorHIDTransportType?, forced: Bool, dtuhiddPresent: Bool?) -> Bool {
        !forced && selected == .indigo && dtuhiddPresent == true
    }

    /// The transport upstream's auto-selection picks for this dtuhidd
    /// presence (`FBSimulator.defaultHIDTransport`), or the override.
    nonisolated static func selectedTransport(override: FBSimulatorHIDTransportType?, dtuhiddPresent: Bool?) -> FBSimulatorHIDTransportType? {
        if let override { return override }
        return dtuhiddPresent.map { $0 ? .dtuhid : .indigo }
    }

    public static func performHIDEvent(_ event: FBSimulatorHIDEvent, for simulatorUDID: String, logger: SimUseLogger) async throws {
        let session = try await makeSession(for: simulatorUDID, logger: logger)
        try await performHIDEvent(event, in: session, logger: logger)
    }

    // Get or create a cached HID connection (matching CompanionLib's connectToHID behavior)
    private static func getOrCreateHIDConnection(for simulator: FBSimulator, logger: SimUseLogger) async throws -> (FBSimulatorHID, FBSimulatorHIDTransportType?) {
        let currentToken = HIDBootIdentity.token(dataDirectory: simulator.dataDirectory, udid: simulator.udid)
        if let cached = hidConnections[simulator.udid] {
            let sameBoot = HIDBootIdentity.isReusable(cachedToken: cached.bootToken, currentToken: currentToken)
            // Only an auto-selected Indigo connection pays for the presence
            // check (a process-table read of a millisecond or two).
            let outdated = cached.transport == .indigo
                && transportOutdated(selected: cached.transport, forced: transportOverride != nil, dtuhiddPresent: dtuhiddPresenceHint(forUDID: simulator.udid))
            if sameBoot && cached.transportTrusted && !outdated {
                logger.info().log("Using existing HID connection for simulator \(simulator.udid)")
                return (cached.hid, cached.transport)
            }
            if sameBoot && outdated {
                // dtuhidd started since the connection was made (fold or
                // rotate with Device Hub closed): it suppresses the legacy
                // keyboard service, so the Indigo connection must go.
                logger.info().log("dtuhidd started in \(simulator.udid) after its Indigo HID connection was made; rebuilding the connection")
            } else if sameBoot {
                // Same boot, but the transport was auto-selected inside
                // the boot-attach trust window (issue #67): dtuhidd may
                // have appeared since the probe, so the selection must
                // be re-derived rather than pinned for the whole boot.
                logger.info().log("Cached HID connection for \(simulator.udid) was created inside the transport trust window; discarding it to re-derive the transport selection")
            } else {
                // The simulator was re-booted (or the boot identity is
                // unknowable) since the connection was made: the cached
                // handle's mach port is dead and must not be sent through.
                logger.info().log("Boot identity changed for simulator \(simulator.udid) (cached: \(cached.bootToken); current: \(currentToken)); discarding cached HID connection")
            }
            cached.hid.disconnect()
            hidConnections.removeValue(forKey: simulator.udid)
        }

        logger.info().log("Creating new HID connection for simulator \(simulator.udid)...")
        // Upstream does not expose which transport its auto-selection
        // resolved to, so log the input signals instead: the forced
        // override when present, otherwise the dtuhidd-presence fact the
        // selection keys on (a ~1–2 ms sysctl probe we already pay for
        // the boot-identity token).
        let dtuhiddPresent = transportOverride == nil ? dtuhiddPresenceHint(forUDID: simulator.udid) : nil
        if let transportOverride {
            logger.info().log("HID transport forced via SIM_USE_HID_TRANSPORT: \(transportOverride)")
        } else {
            let presence = dtuhiddPresent.map { $0 ? "present" : "absent" } ?? "unknown"
            logger.info().log("HID transport: auto (dtuhidd in this simulator's process tree: \(presence); upstream selects DTUHID when present)")
        }
        // Bare construction, not `simulator.connectToHID()`: upstream's
        // lifecycle wrapper keeps its own per-simulator cache with no
        // boot-identity gate, which would resurrect exactly the stale
        // handles this cache invalidates (issue #55). Transport selection
        // stays automatic (`FBSimulator.defaultHIDTransport`) unless the
        // debug override is set.
        let hid = try FBSimulatorHID(for: simulator, transport: transportOverride)

        // A forced transport cannot race dtuhidd's boot-time attach;
        // only the auto-selection is window-gated.
        let transportTrusted = transportOverride != nil
            || HIDBootIdentity.isTransportSelectionTrustworthy(token: currentToken, now: Date())
        let transport = selectedTransport(override: transportOverride, dtuhiddPresent: dtuhiddPresent)
        hidConnections[simulator.udid] = CachedConnection(
            hid: hid, bootToken: currentToken, transportTrusted: transportTrusted, transport: transport)
        if transportTrusted {
            logger.info().log("HID connection created and cached for simulator \(simulator.udid)")
        } else {
            logger.info().log("HID connection created for simulator \(simulator.udid) inside the transport trust window (launchd_sim uptime < \(Int(HIDBootIdentity.transportTrustWindow)) s); the next command re-derives the transport selection")
        }

        return (hid, transport)
    }

    /// Whether a `dtuhidd` currently lives in the simulator's
    /// `launchd_sim` subtree — the signal upstream's transport
    /// auto-selection keys on. Diagnostic only (logged above); nil when
    /// the process table cannot be read.
    private static func dtuhiddPresenceHint(forUDID udid: String) -> Bool? {
        guard let table = LaunchdSimLocator.processTable(),
              let launchdSim = LaunchdSimLocator.record(
                  forUDID: udid, in: table,
                  argumentsForPID: LaunchdSimLocator.argumentBlob(forPID:))
        else {
            return nil
        }
        return table.contains { $0.ppid == launchdSim.pid && $0.command == "dtuhidd" }
    }

    public static func clearHIDConnections() {
        for cached in hidConnections.values {
            cached.hid.disconnect()
        }
        hidConnections.removeAll()
    }

    /// Drop the cached HID connection for a single UDID. Used by
    /// daemon stale-simulator detection (LINEIOS-216942): once the
    /// daemon proves the simulator was shut down out of band, the
    /// cached `FBSimulatorHID` handle is dead and must not be reused
    /// even if the same UDID is re-booted before the daemon process
    /// itself terminates.
    public static func clearHIDConnection(for simulatorUDID: String) {
        hidConnections[simulatorUDID]?.hid.disconnect()
        hidConnections.removeValue(forKey: simulatorUDID)
    }
}

extension FBSimulatorHIDEvent {
    /// True for a touch, a two-finger touch, or a composite holding one.
    var containsTouch: Bool {
        switch self {
        case .touch, .twoFingerTouch:
            return true
        case .composite(let events):
            return events.contains { $0.containsTouch }
        default:
            return false
        }
    }
}
