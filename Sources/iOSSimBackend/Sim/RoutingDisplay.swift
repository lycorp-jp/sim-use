// SPDX-License-Identifier: Apache-2.0
import FBSimulatorControl
import Foundation
import SimUseCore

// MARK: - Routing display

/// The display that hosts the frontmost app, which is the display every
/// input, accessibility and capture primitive has to address.
///
/// | State | Routing display |
/// | --- | --- |
/// | Resize Mode session active | the virtual `Resizable` display |
/// | more than one integrated display, a non-primary one active | that display (iPhone Duo inner screen) |
/// | otherwise | the main display — the historical, unchanged path |
///
/// Work record: docs/ai/010-display-routing/000-plan.md.
public enum RoutingDisplay: Equatable, Sendable {
    case main
    /// A non-primary integrated display hosts the interface (an unfolded
    /// iPhone Duo).
    case secondary(SimulatorDisplay)
    /// A Resize Mode session (issue #143). The display entry is nil when
    /// the topology could not be read.
    case resizable(ResizableAppSession, SimulatorDisplay?)

    public var isMain: Bool { self == .main }

    public var displayName: String? {
        switch self {
        case .main: return nil
        case .secondary(let display): return display.name
        case .resizable(let session, let display): return display?.name ?? session.displayName
        }
    }

    /// The CoreDevice display UUID to capture, nil for the main display.
    public var captureUniqueID: String? {
        switch self {
        case .main: return nil
        case .secondary(let display): return display.uniqueID
        case .resizable(let session, _): return session.displayUniqueID
        }
    }

    /// The interface orientation of a secondary display, from CoreDevice.
    /// A Resize Mode scene is always upright (sessions refuse to start
    /// rotated — plan E17).
    public var interfaceOrientation: DisplayOrientation? {
        switch self {
        case .main: return nil
        case .secondary(let display): return display.rotation.interfaceOrientation
        case .resizable: return .portrait
        }
    }

    /// The unrotated panel of a secondary display in points.
    public var panelPoints: NativePortraitSize? {
        if case .secondary(let display) = self { return display.panelPoints }
        return nil
    }

    /// Serialised into `describe-ui --json` only off the main display.
    public var info: RoutingDisplayInfo? {
        switch self {
        case .main:
            return nil
        case .secondary(let display):
            return RoutingDisplayInfo(
                name: display.name,
                id: Int(display.displayID),
                kind: display.kind.label,
                primary: display.isPrimary,
                rotation: display.rotation.rawValue,
                resizableSession: nil
            )
        case .resizable(let session, let display):
            return RoutingDisplayInfo(
                name: display?.name ?? session.displayName,
                id: display.map { Int($0.displayID) },
                kind: display?.kind.label ?? SimulatorDisplay.Kind.virtual.label,
                primary: false,
                rotation: SimulatorDisplayRotation.rot0.rawValue,
                resizableSession: .init(preferredWidth: session.preferredWidth, preferredHeight: session.preferredHeight)
            )
        }
    }

    /// Appended to the outline `App:` header off the main display, so the
    /// common single-display header stays byte-identical.
    public var headerTag: String? {
        switch self {
        case .main:
            return nil
        case .secondary(let display):
            return "display \(display.name)"
        case .resizable(let session, let display):
            return "display \(display?.name ?? session.displayName) \(session.preferredSizeDescription)"
        }
    }
}

// MARK: - Addressing a routing display

extension RoutingDisplay {
    /// The AX translator display the hit-test and the tree fetch address:
    /// the CoreDevice display id (plan E6, E7, E15). 0 is the main display.
    public var accessibilityDisplayID: UInt32 {
        switch self {
        case .main: return 0
        case .secondary(let display): return display.displayID
        case .resizable(_, let display): return display?.displayID ?? 0
        }
    }

    /// The UI → HID / hit-test transform off the main display, known from
    /// CoreDevice without hit-test probes. A secondary display maps through
    /// its rotation onto its unrotated panel (plan E4). A Resize Mode scene
    /// is upright and sits at the canvas origin, so its points pass through
    /// (E14); `sceneSize` is its size in points, when known. Nil on the
    /// main display, which keeps the self-calibration.
    public func fixedCalibration(sceneSize: CGSize?) -> OrientationCalibration? {
        switch self {
        case .main:
            return nil
        case .secondary(let display):
            return OrientationCalibration(
                orientation: display.rotation.interfaceOrientation,
                native: display.panelPoints,
                probesUsed: 0,
                advisory: nil
            )
        case .resizable:
            return .identity(native: sceneSize.map { NativePortraitSize(width: Double($0.width), height: Double($0.height)) })
        }
    }

    /// Where touch input goes. Nil on the main display (the historical
    /// path). A Resize Mode session normalizes scene points against the
    /// whole `Resizable` canvas in pixels (E14, E18); a secondary display
    /// against its panel.
    public func hidRoute() throws -> FBSimulatorHIDDisplayRoute? {
        switch self {
        case .main:
            return nil
        case .secondary(let display):
            return Self.route(for: display)
        case .resizable(let session, let display):
            guard let display else {
                throw CLIError(errorDescription: "A resizable app session is active, but CoreDevice did not list its '\(session.displayName)' display (\(session.displayUniqueID)), so touch input cannot be routed to it. Re-run the command; if it persists, end the session.")
            }
            return Self.route(for: display)
        }
    }

    /// What a video capture reads off the main display: the framebuffer
    /// port of that display, named by its unrotated pixel size, and the part
    /// that shows the app. Nil on the main display (the historical path).
    /// The inner iPhone Duo panel is captured whole, in its native portrait
    /// orientation like the main display; a Resize Mode scene sits at the
    /// origin of the `Resizable` canvas (E14), so the capture is cut to it.
    public func captureSource() throws -> CaptureSource? {
        switch self {
        case .main:
            return nil
        case .secondary(let display):
            return CaptureSource(display: display, crop: nil)
        case .resizable(let session, let display):
            guard let display else {
                throw CLIError(errorDescription: "A resizable app session is active, but CoreDevice did not list its '\(session.displayName)' display (\(session.displayUniqueID)), so it cannot be captured. Re-run the command; if it persists, end the session.")
            }
            let scale = display.pointScale
            return CaptureSource(
                display: display,
                crop: CGRect(x: 0, y: 0, width: session.preferredWidth * scale, height: session.preferredHeight * scale)
            )
        }
    }

    private static func route(for display: SimulatorDisplay) -> FBSimulatorHIDDisplayRoute {
        FBSimulatorHIDDisplayRoute(
            digitizerTarget: UInt64(display.displayID),
            screenSize: CGSize(width: display.pixelWidth, height: display.pixelHeight),
            screenScale: Float(display.pointScale)
        )
    }
}

/// The framebuffer a capture of a non-main display reads.
public struct CaptureSource: Equatable, Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Pixels, top-left origin; nil captures the whole display.
    public let crop: CGRect?
    public let displayName: String

    init(display: SimulatorDisplay, crop: CGRect?) {
        self.pixelWidth = Int(display.pixelWidth.rounded())
        self.pixelHeight = Int(display.pixelHeight.rounded())
        self.crop = crop
        self.displayName = display.name
    }
}

/// The `display` object of `describe-ui --json`. Present only when the app
/// is not on the main display.
public struct RoutingDisplayInfo: Codable, Equatable, Sendable {
    public struct ResizableSessionInfo: Codable, Equatable, Sendable {
        public let preferredWidth: Double
        public let preferredHeight: Double
    }

    public let name: String
    public let id: Int?
    public let kind: String
    public let primary: Bool
    public let rotation: String
    public let resizableSession: ResizableSessionInfo?
}

public enum RoutingDisplayResolver {
    /// Pure resolution, pinned by tests. The session wins: during a Resize
    /// Mode session the app is on the `Resizable` display whatever the
    /// integrated displays do.
    public static func resolve(
        session: ResizableAppSessionState,
        topology: SimulatorDisplayTopologyState
    ) -> RoutingDisplay {
        if case .active(let resizable) = session {
            return .resizable(resizable, topology.topology?.display(uniqueID: resizable.displayUniqueID))
        }
        guard let topology = topology.topology, topology.isMultiDisplay,
              let active = topology.activeIntegrated, !active.isPrimary
        else {
            return .main
        }
        return .secondary(active)
    }

    /// Reads both monitors. `evidence` is forwarded to the session monitor
    /// (see `ResizableAppSessionMonitor.state(for:evidence:)`).
    public static func current(
        udid: String,
        evidence: ResizableAppSessionMonitor.SceneEvidence? = nil,
        deviceSizedRoot: Bool = false,
        rootSize: SimulatorDisplayTopologyMonitor.RootSize? = nil,
        sessionMonitor: ResizableAppSessionMonitor = .shared,
        topologyMonitor: SimulatorDisplayTopologyMonitor = .shared
    ) async -> RoutingDisplay {
        let session = await sessionMonitor.state(for: udid, evidence: evidence, deviceSizedRoot: deviceSizedRoot)
        var topology = await topologyMonitor.state(for: udid, rootSize: rootSize)
        // Display UUIDs change on every boot, and a single-display answer is
        // kept for the life of the daemon: a session display the cached
        // topology does not list means the simulator rebooted since. Read
        // the topology again once (R158-04).
        if case .active(let resizable) = session,
           let cached = topology.topology, cached.display(uniqueID: resizable.displayUniqueID) == nil
        {
            topology = await topologyMonitor.state(for: udid, fresh: true)
        }
        return resolve(session: session, topology: topology)
    }
}

// MARK: - Guard

/// A verb refused because the app is not on a display it can address. The
/// refusal is final: batch rethrows it unchanged so the hint reaches the
/// error envelope.
public protocol RoutingDisplayRefusal: LocalizedError, HintProviding {}

/// Thrown instead of starting a video capture of the main display while the
/// app is on a secondary integrated display.
public struct SecondaryDisplayCaptureError: RoutingDisplayRefusal, Equatable {
    public let verb: String
    public let udid: String
    public let display: SimulatorDisplay

    public init(verb: String, udid: String, display: SimulatorDisplay) {
        self.verb = verb
        self.udid = udid
        self.display = display
    }

    public var errorDescription: String? {
        "The frontmost app on simulator \(udid) is on display '\(display.name)' (id \(display.displayID)), " +
            "but `\(verb)` captures only the main display, which is dark while '\(display.name)' is active. Nothing was captured."
    }

    public var hint: String? {
        "Use `stream-video --format h264` or `--format bgra`, or `record-video`, which capture '\(display.name)'. " +
            "Set \(SimulatorDisplayTopologyMonitor.disableEnvironmentKey)=0 to skip this check."
    }
}

public enum RoutingDisplayGuard {
    /// What a video capture reads (docs/ai/010-display-routing, S5): nil on
    /// the main display, else the framebuffer of the display that hosts
    /// the app.
    public static func captureSource(
        udid: String,
        verb: String,
        logger: SimUseLogger,
        sessionMonitor: ResizableAppSessionMonitor = .shared,
        topologyMonitor: SimulatorDisplayTopologyMonitor = .shared
    ) async throws -> CaptureSource? {
        let routing = await RoutingDisplayResolver.current(udid: udid, sessionMonitor: sessionMonitor, topologyMonitor: topologyMonitor)
        guard let source = try routing.captureSource() else { return nil }
        logger.info().log("\(verb) captures display '\(source.displayName)' (\(source.pixelWidth)x\(source.pixelHeight) px\(source.crop.map { ", cut to \(Int($0.width))x\(Int($0.height))" } ?? ""))")
        return source
    }

    /// A note for the end of a capture whose app moved to another display
    /// while it ran (a fold, a Resize Mode session that started or ended):
    /// the capture keeps the display it started on. Nil when it did not move.
    public static func captureMovedNotice(
        udid: String,
        verb: String,
        started: CaptureSource?,
        sessionMonitor: ResizableAppSessionMonitor = .shared,
        topologyMonitor: SimulatorDisplayTopologyMonitor = .shared
    ) async -> String? {
        let now = try? await RoutingDisplayResolver.current(udid: udid, sessionMonitor: sessionMonitor, topologyMonitor: topologyMonitor).captureSource()
        guard now != started else { return nil }
        let before = started?.displayName ?? "the main display"
        let after = now.map { "display '\($0.displayName)'" } ?? "the main display"
        return "[i] The app moved to \(after) while `\(verb)` ran; the video shows \(started == nil ? before : "display '\(before)'") only, as it was when the capture started.\n"
    }

    /// Call after global setup in every verb that dispatches touch HID.
    /// Touch input reaches the display that hosts the app, so this only
    /// fails when that display cannot be addressed: a Resize Mode session
    /// whose display CoreDevice did not list. The route itself is applied
    /// per event by `HIDInteractor.routeTouches`. `verb` is kept for the log.
    public static func assertTouchInputReachesApp(
        udid: String,
        verb: String,
        logger: SimUseLogger,
        sessionMonitor: ResizableAppSessionMonitor = .shared,
        topologyMonitor: SimulatorDisplayTopologyMonitor = .shared
    ) async throws {
        let routing = await RoutingDisplayResolver.current(udid: udid, sessionMonitor: sessionMonitor, topologyMonitor: topologyMonitor)
        if let name = routing.displayName {
            logger.info().log("\(verb): the app is on display \(name); touch input is routed there")
        }
        _ = try routing.hidRoute()
    }

    /// Call after global setup in every verb that captures the main
    /// framebuffer without redirection (`record-video`, `stream-video`),
    /// before any output file is created or byte is emitted.
    public static func assertCaptureReachesApp(
        udid: String,
        verb: String,
        logger: SimUseLogger,
        sessionMonitor: ResizableAppSessionMonitor = .shared,
        topologyMonitor: SimulatorDisplayTopologyMonitor = .shared
    ) async throws {
        switch await RoutingDisplayResolver.current(udid: udid, sessionMonitor: sessionMonitor, topologyMonitor: topologyMonitor) {
        case .main:
            return
        case .resizable(let session, _):
            logger.info().log("Resizable app session active on \(udid) (\(session.displayName) \(session.preferredSizeDescription)); refusing \(verb) (main-display capture only)")
            throw ResizableAppSessionCaptureError(verb: verb, udid: udid, session: session)
        case .secondary(let display):
            logger.info().log("App is on secondary display \(display.name) of \(udid); refusing \(verb) (main-display capture only)")
            throw SecondaryDisplayCaptureError(verb: verb, udid: udid, display: display)
        }
    }
}
