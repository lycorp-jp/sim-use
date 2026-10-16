// SPDX-License-Identifier: Apache-2.0
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
        rootSize: SimulatorDisplayTopologyMonitor.RootSize? = nil,
        sessionMonitor: ResizableAppSessionMonitor = .shared,
        topologyMonitor: SimulatorDisplayTopologyMonitor = .shared
    ) async -> RoutingDisplay {
        let session = await sessionMonitor.state(for: udid, evidence: evidence)
        let topology = await topologyMonitor.state(for: udid, rootSize: rootSize)
        return resolve(session: session, topology: topology)
    }
}

// MARK: - Advisories and refusals for read paths

public enum SecondaryDisplayAdvisory {
    /// For `describe-ui` while the app is on a secondary integrated display.
    public static func describeUI(display: SimulatorDisplay) -> CommandAdvisory {
        CommandAdvisory(
            kind: .secondaryDisplay,
            message: "The app is on display '\(display.name)' (id \(display.displayID), \(display.rotation.interfaceOrientation.rawValue)), not the main display. " +
                "The outline is the app's own tree; hit-test recovery was skipped and the orientation comes from CoreDevice. " +
                "Touch verbs and record-video / stream-video are refused on this display; `type`, the key verbs and `screenshot` work."
        )
    }
}

/// Thrown by `describe-ui --point` on a secondary integrated display: the
/// point hit-test resolves on the main display, which is dark.
public struct SecondaryDisplayPointQueryError: RoutingDisplayRefusal, Equatable {
    public let udid: String
    public let display: SimulatorDisplay

    public init(udid: String, display: SimulatorDisplay) {
        self.udid = udid
        self.display = display
    }

    public var errorDescription: String? {
        "The frontmost app on simulator \(udid) is on display '\(display.name)' (id \(display.displayID)), but point hit-tests resolve on the main display, " +
            "so `describe-ui --point` cannot describe the app."
    }

    public var hint: String? {
        "Use the full `describe-ui` outline, which reads the app's own tree on '\(display.name)'."
    }
}

// MARK: - Guard

/// A verb refused because the app is not on a display it can address. The
/// refusal is final: batch rethrows it unchanged so the hint reaches the
/// error envelope.
public protocol RoutingDisplayRefusal: LocalizedError, HintProviding {}

/// Thrown instead of dispatching a touch while the app is on a secondary
/// integrated display that this build cannot route touch input to.
public struct SecondaryDisplayInputError: RoutingDisplayRefusal, Equatable {
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
            "an integrated display that is not the main display (for example the unfolded iPhone Duo inner screen). " +
            "Simulator touch input reaches only the main display, so this \(verb) would report success and deliver nothing. No input was sent."
    }

    public var hint: String? {
        "Fold the device so the app returns to the main display (`sim-use ios fold closed`) and retry. " +
            "`ui`, `screenshot`, `type` and the key verbs keep working on '\(display.name)'. " +
            "Set \(SimulatorDisplayTopologyMonitor.disableEnvironmentKey)=0 to skip this check."
    }
}

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
        "Use `screenshot`, which captures '\(display.name)' automatically, or record it with " +
            "`xcrun simctl io \(udid) recordVideo --display=\(display.uniqueID) <file.mov>`. " +
            "Set \(SimulatorDisplayTopologyMonitor.disableEnvironmentKey)=0 to skip this check."
    }
}

public enum RoutingDisplayGuard {
    /// Call after global setup in every verb that dispatches touch HID.
    /// `verb` names the surface in the error ("tap", "swipe", "batch", ...).
    public static func assertTouchInputReachesApp(
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
            logger.info().log("Resizable app session active on \(udid) (\(session.displayName) \(session.preferredSizeDescription)); refusing \(verb)")
            throw ResizableAppSessionError(verb: verb, udid: udid, session: session)
        case .secondary(let display):
            logger.info().log("App is on secondary display \(display.name) (id \(display.displayID)) of \(udid); refusing \(verb)")
            throw SecondaryDisplayInputError(verb: verb, udid: udid, display: display)
        }
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
