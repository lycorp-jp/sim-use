// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

// MARK: - Report

/// The posture a simulator reports through CoreDevice: which display hosts
/// the interface, its orientation, and any Resize Mode session.
public struct PostureReport: Codable, Equatable, Sendable {
    public struct Display: Codable, Equatable, Sendable {
        public let name: String
        public let id: Int
        public let primary: Bool
        public let rotation: String
        /// sim-use interface orientation (`DisplayOrientation` raw value).
        public let orientation: String
        public let backlight: String?

        init(_ display: SimulatorDisplay) {
            name = display.name
            id = Int(display.displayID)
            primary = display.isPrimary
            rotation = display.rotation.rawValue
            orientation = display.rotation.interfaceOrientation.rawValue
            backlight = display.backlightState
        }
    }

    public struct Session: Codable, Equatable, Sendable {
        public let preferredWidth: Double
        public let preferredHeight: Double
    }

    /// The integrated display that hosts the interface.
    public let activeDisplay: Display?
    /// Names of every integrated display, primary first.
    public let integratedDisplays: [String]
    /// Device convention (devicectl `currentDeviceOrientation`).
    public let deviceOrientation: String?
    public let resizableSession: Session?

    public init(topology: SimulatorDisplayTopology, session: ResizableAppSession?) {
        activeDisplay = (topology.activeIntegrated ?? topology.primary).map(Display.init)
        integratedDisplays = topology.integratedDisplays
            .sorted { $0.isPrimary && !$1.isPrimary }
            .map(\.name)
        deviceOrientation = topology.deviceOrientation
        resizableSession = session.map { Session(preferredWidth: $0.preferredWidth, preferredHeight: $0.preferredHeight) }
    }

    /// One line for the text output.
    public var summary: String {
        var parts: [String] = []
        if let display = activeDisplay {
            parts.append("active display \(display.name) (id \(display.id)\(display.primary ? ", primary" : "")), \(display.orientation)")
        } else {
            parts.append("no active integrated display")
        }
        if integratedDisplays.count > 1 {
            parts.append("integrated displays: \(integratedDisplays.joined(separator: ", "))")
        }
        if let deviceOrientation {
            parts.append("device orientation \(deviceOrientation)")
        }
        if let session = resizableSession {
            parts.append("Resize Mode session \(ResizableAppSession.format(session.preferredWidth))x\(ResizableAppSession.format(session.preferredHeight))")
        }
        return parts.joined(separator: "; ")
    }
}

// MARK: - Fold

/// The hinge position `ios fold` sets.
public enum FoldTarget: Equatable, Sendable, CustomStringConvertible {
    case closed
    case half
    case open
    case degrees(Double)

    /// Device Hub's half-open preset (also duo-fold-control's `half`).
    static let halfDegrees = 130.0

    public init?(argument: String) {
        switch argument.lowercased() {
        case "closed", "close", "folded": self = .closed
        case "half", "half-open": self = .half
        case "open", "flat", "unfolded": self = .open
        default:
            guard let value = Double(argument), value.isFinite, (0...180).contains(value) else { return nil }
            self = .degrees(value)
        }
    }

    public var degrees: Double {
        switch self {
        case .closed: return 0
        case .half: return Self.halfDegrees
        case .open: return 180
        case .degrees(let value): return value
        }
    }

    /// Which display must end up active. Only 0° and 180° are
    /// deterministic: at an intermediate angle the active display depends
    /// on the path the hinge took (plan E21), so it is observed, not
    /// expected. Explicit 0 and 180 are the same positions as the names.
    public var expectation: FoldExpectation {
        switch degrees {
        case 0: return .primaryActive
        case 180: return .secondaryActive
        default: return .observeOnly
        }
    }

    public var description: String {
        switch self {
        case .closed: return "closed"
        case .half: return "half"
        case .open: return "open"
        case .degrees(let value): return "\(ResizableAppSession.format(value))°"
        }
    }
}

public enum FoldExpectation: Equatable, Sendable {
    case primaryActive
    case secondaryActive
    case observeOnly

    /// True when `topology` shows the expected display active.
    func isMet(by topology: SimulatorDisplayTopology) -> Bool {
        guard let active = topology.activeIntegrated else { return false }
        switch self {
        case .primaryActive: return active.isPrimary
        case .secondaryActive: return !active.isPrimary
        case .observeOnly: return true
        }
    }

    /// True when a hinge report left no trace: the expectation is unmet
    /// and the display that was active before still is. A report can be
    /// lost on the way to the guest (plan E53); sending the same angle
    /// again is harmless.
    func reportHadNoEffect(before: SimulatorDisplayTopology, after: SimulatorDisplayTopology) -> Bool {
        guard self != .observeOnly, !isMet(by: after) else { return false }
        return before.activeIntegrated?.uniqueID == after.activeIntegrated?.uniqueID
    }
}

// MARK: - Rotate

/// Quarter turns, the unit both the device orientation and a display
/// rotation are measured in. Device convention: device `landscapeRight`
/// turns the main display's interface to `rot90`.
enum QuarterTurn {
    static func of(deviceOrientation: String) -> Int? {
        switch deviceOrientation {
        case "portrait": return 0
        case "landscapeRight": return 1
        case "portraitUpsideDown": return 2
        case "landscapeLeft": return 3
        default: return nil // unknown, faceUp, faceDown
        }
    }

    static func of(rotation: SimulatorDisplayRotation) -> Int {
        switch rotation {
        case .rot0: return 0
        case .rot90: return 1
        case .rot180: return 2
        case .rot270: return 3
        }
    }

    static func of(interface orientation: DisplayOrientation) -> Int {
        switch orientation {
        case .portrait: return 0
        case .landscapeLeft: return 1
        case .portraitUpsideDown: return 2
        case .landscapeRight: return 3
        }
    }

    static func deviceOrientation(_ turns: Int) -> DeviceOrientationValue {
        switch ((turns % 4) + 4) % 4 {
        case 0: return .portrait
        case 1: return .landscapeRight
        case 2: return .portraitUpsideDown
        default: return .landscapeLeft
        }
    }
}

/// A device orientation in device convention (devicectl names).
public enum DeviceOrientationValue: String, Equatable, Sendable, Codable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    /// The orientation picker's value for this device orientation.
    var virtualMachineValue: VirtualMachineOrientation {
        switch self {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        }
    }
}

public enum RotationPlanner {
    /// The device orientation (devicectl convention) that shows `target`
    /// on the display that hosts the app. CoreDevice reports every
    /// integrated display's rotation in the same frame as the device
    /// orientation — the Duo cover shows `rot0` for `portrait`, the inner
    /// screen `rot90` for `landscapeRight` — so no per-display offset.
    static func deviceOrientation(for target: DisplayOrientation) -> DeviceOrientationValue {
        QuarterTurn.deviceOrientation(QuarterTurn.of(interface: target))
    }

    /// How many quarter turns the device orientation CoreDevice reports
    /// sits from the orientation picker value that produced it. 0 on a
    /// primary display. Unfolded, the iPhone Duo reports one quarter turn
    /// more than the picker value (picker `portrait` reads back as
    /// `landscapeRight` — plan E2): the first guess for any secondary
    /// display, corrected from the read-back when it is wrong.
    static func initialTransportOffset(display: SimulatorDisplay?) -> Int {
        guard let display, !display.isPrimary else { return 0 }
        return 1
    }

    /// The value to send so that the device reports `device`.
    static func sendValue(for device: DeviceOrientationValue, transportOffset: Int) -> DeviceOrientationValue {
        QuarterTurn.deviceOrientation(QuarterTurn.of(deviceOrientation: device.rawValue)! - transportOffset)
    }

    /// True when a read-back is the answer to a rotation: two reads agree
    /// on the device orientation and the routing display's rotation, and
    /// either both reached the target or `grace` has passed. Anything
    /// short of the target needs the grace, because the first reads can
    /// still show the state from before, and the interface can follow the
    /// device orientation late (plan open question 18).
    static func readBackSettled(
        previous: SimulatorDisplayTopology?,
        current: SimulatorDisplayTopology,
        wanted: DeviceOrientationValue,
        target: DisplayOrientation,
        elapsed: TimeInterval,
        grace: TimeInterval
    ) -> Bool {
        guard let previous, let reported = current.deviceOrientation,
              previous.deviceOrientation == reported,
              previous.routingRotation == current.routingRotation
        else { return false }
        let reachedTarget = reported == wanted.rawValue && current.routingRotation?.interfaceOrientation == target
        return reachedTarget || elapsed >= grace
    }

    /// True when a rotation left no trace: the device orientation and the
    /// routing display's rotation read back as before, short of the
    /// target. A lost report and a refused orientation look the same, and
    /// one more send of the same value is harmless for both.
    static func reportHadNoEffect(before: SimulatorDisplayTopology?, after: SimulatorDisplayTopology, target: DisplayOrientation) -> Bool {
        guard let before, after.routingRotation?.interfaceOrientation != target else { return false }
        return before.deviceOrientation == after.deviceOrientation && before.routingRotation == after.routingRotation
    }

    /// The offset a read-back reveals: `reported` came back for `sent`.
    static func learnedTransportOffset(sent: DeviceOrientationValue, reported: String) -> Int? {
        guard let reportedTurns = QuarterTurn.of(deviceOrientation: reported),
              let sentTurns = QuarterTurn.of(deviceOrientation: sent.rawValue)
        else { return nil }
        return ((reportedTurns - sentTurns) % 4 + 4) % 4
    }
}

extension SimulatorDisplayTopology {
    /// The rotation of the display a rotation is confirmed on: the active
    /// integrated display, else the primary one.
    var routingRotation: SimulatorDisplayRotation? {
        (activeIntegrated ?? primary)?.rotation
    }
}
