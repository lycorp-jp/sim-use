// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

// MARK: - Model

/// The rotation CoreDevice reports for a display (`currentOrientation`):
/// how far the interface is turned from the panel's native orientation.
/// Names and raw values follow devicectl and upstream idb
/// (`SimulatorDisplayRotation`) so the idb migration only swaps the source.
public enum SimulatorDisplayRotation: String, Equatable, Sendable, Codable, CaseIterable {
    case rot0
    case rot90
    case rot180
    case rot270

    /// The interface orientation sim-use prints for this rotation. rot90
    /// is `landscape-left` in sim-use's naming (verified live: devicectl
    /// device orientation `landscapeRight` gives `rot90`, and the
    /// orientation self-calibration reads the same screen as
    /// `landscape-left`). `DisplayOrientation.uiToFramebuffer` then gives
    /// exactly the measured panel mapping for each rotation.
    /// Work record: docs/ai/010-display-routing/000-plan.md (E4, E10).
    public var interfaceOrientation: DisplayOrientation {
        switch self {
        case .rot0: return .portrait
        case .rot90: return .landscapeLeft
        case .rot180: return .portraitUpsideDown
        case .rot270: return .landscapeRight
        }
    }
}

/// One display of a booted simulator, as `devicectl device info displays`
/// describes it.
public struct SimulatorDisplay: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A panel built into the device (iPhone LCD; both iPhone Duo panels).
        case integrated
        /// A display that exists only in software (the Resize Mode
        /// `Resizable` canvas, always listed on Xcode 27 iPhones).
        case virtual
        case other(String)

        var label: String {
            switch self {
            case .integrated: return "integrated"
            case .virtual: return "virtual"
            case .other(let name): return name
            }
        }
    }

    /// CoreDevice display id. Also the AX translator `displayId` and the
    /// low byte of the dtuhidd touchscreen service for the display
    /// (`touchscreen(0x103)` for id 3) — plan E3, E6, E7.
    public let displayID: UInt32
    /// CoreDevice display UUID; the display name on runtimes before iOS 27,
    /// which report none. Changes on every boot; never persist it.
    public let uniqueID: String
    public let name: String
    public let kind: Kind
    public let isPrimary: Bool
    /// Hosts the interface now. This is the signal, not the backlight: a
    /// locked device keeps its active display `active` with the backlight
    /// dimmed (`inactiveOn`) — plan E19.
    public let isActive: Bool
    public let backlightState: String?
    public let rotation: SimulatorDisplayRotation
    /// Panel size in pixels, unrotated.
    public let pixelWidth: Double
    public let pixelHeight: Double
    public let pointScale: Double

    public init(
        displayID: UInt32,
        uniqueID: String,
        name: String,
        kind: Kind,
        isPrimary: Bool,
        isActive: Bool,
        backlightState: String?,
        rotation: SimulatorDisplayRotation,
        pixelWidth: Double,
        pixelHeight: Double,
        pointScale: Double
    ) {
        self.displayID = displayID
        self.uniqueID = uniqueID
        self.name = name
        self.kind = kind
        self.isPrimary = isPrimary
        self.isActive = isActive
        self.backlightState = backlightState
        self.rotation = rotation
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointScale = pointScale
    }

    /// The unrotated panel in points. For the virtual `Resizable` display
    /// this is the whole canvas (2560x1440 for 7680x4320 @3x), not the
    /// scene of a session.
    public var panelPoints: NativePortraitSize? {
        guard pointScale > 0, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return NativePortraitSize(width: pixelWidth / pointScale, height: pixelHeight / pointScale)
    }
}

/// Every display of one simulator plus the device orientation.
public struct SimulatorDisplayTopology: Equatable, Sendable {
    public let displays: [SimulatorDisplay]
    /// devicectl `currentDeviceOrientation` (device convention, e.g.
    /// `landscapeRight`); nil when not reported.
    public let deviceOrientation: String?

    public init(displays: [SimulatorDisplay], deviceOrientation: String?) {
        self.displays = displays
        self.deviceOrientation = deviceOrientation
    }

    public var integratedDisplays: [SimulatorDisplay] {
        displays.filter { $0.kind == .integrated }
    }

    /// More than one integrated display (iPhone Duo). The only gate for the
    /// multi-display paths: the virtual `Resizable` display is listed on
    /// every Xcode 27 iPhone, so a raw display count would match them all.
    public var isMultiDisplay: Bool {
        integratedDisplays.count > 1
    }

    public var primary: SimulatorDisplay? {
        displays.first { $0.isPrimary } ?? integratedDisplays.first
    }

    /// The integrated display that hosts the interface now.
    public var activeIntegrated: SimulatorDisplay? {
        integratedDisplays.first { $0.isActive }
    }

    public func display(uniqueID: String) -> SimulatorDisplay? {
        displays.first { $0.uniqueID.caseInsensitiveCompare(uniqueID) == .orderedSame }
    }
}

public enum SimulatorDisplayTopologyState: Equatable, Sendable {
    case available(SimulatorDisplayTopology)
    /// devicectl could not answer (no `info displays` subcommand, unknown
    /// device, spawn failure, timeout) or the check is disabled. Callers
    /// fall back to the main-display behaviour.
    case unavailable(reason: String)

    public var topology: SimulatorDisplayTopology? {
        if case .available(let topology) = self { return topology }
        return nil
    }
}

// MARK: - Probe (devicectl)

/// Reads the display list through `devicectl device info displays` (~0.1 s,
/// plan E9). Works with the devicectl of Xcode 26.6, 27.0 and 27.1.
public enum SimulatorDisplayTopologyProbe {
    /// Pinned by test. Same shape as `ResizableAppSessionProbe.arguments`.
    public static func arguments(udid: String) -> [String] {
        [
            "devicectl", "device", "info", "displays",
            "--device", udid,
            "--json-output", "-",
            "--timeout", "5",
            "--quiet",
        ]
    }

    public static func classify(_ output: DevicectlQueryOutput) -> SimulatorDisplayTopologyState {
        if let result = output.document?["result"] as? [String: Any],
           let rawDisplays = result["displays"] as? [[String: Any]]
        {
            let displays = rawDisplays.compactMap(display(from:))
            guard !displays.isEmpty else {
                return .unavailable(reason: "devicectl listed no readable display")
            }
            let orientation = (result["orientation"] as? [String: Any])?["currentDeviceOrientation"] as? String
            return .available(SimulatorDisplayTopology(displays: displays, deviceOrientation: orientation))
        }
        if let error = output.errorSummary {
            return .unavailable(reason: error.summary)
        }
        if output.isUnknownSubcommand {
            return .unavailable(reason: "devicectl has no `device info displays` subcommand")
        }
        let trimmed = output.combinedText
        return .unavailable(reason: "devicectl exited \(output.terminationStatus)\(trimmed.isEmpty ? "" : ": \(trimmed.prefix(300))")")
    }

    public static func run(udid: String, executablePath: String = "/usr/bin/xcrun") -> SimulatorDisplayTopologyState {
        var spawnFailure = "could not spawn xcrun devicectl"
        guard let output = DevicectlQuery.run(
            arguments: arguments(udid: udid),
            executablePath: executablePath,
            spawnError: { spawnFailure = $0 }
        ) else {
            return .unavailable(reason: spawnFailure)
        }
        return classify(output)
    }

    /// One display entry. Entries without an id or a size are dropped
    /// rather than guessed.
    static func display(from raw: [String: Any]) -> SimulatorDisplay? {
        guard let id = DevicectlQuery.number(raw["displayId"]), id >= 0, id <= Double(UInt32.max) else { return nil }
        let name = (raw["name"] as? String) ?? "display \(Int(id))"
        // Runtimes before iOS 27 report no `uniqueId` (verified on iOS 18.6
        // and 26.5); the name identifies the display there, and `simctl io
        // --display` accepts it too.
        let uniqueID = (raw["uniqueId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name

        // `bounds` is `[[x, y], [w, h]]`; `nativeSize` is `[w, h]`. Both
        // carry the unrotated panel in pixels.
        var size: (Double, Double)?
        if let bounds = raw["bounds"] as? [[Any]], bounds.count == 2, bounds[1].count == 2,
           let w = DevicectlQuery.number(bounds[1][0]), let h = DevicectlQuery.number(bounds[1][1]) {
            size = (w, h)
        } else if let native = raw["nativeSize"] as? [Any], native.count == 2,
                  let w = DevicectlQuery.number(native[0]), let h = DevicectlQuery.number(native[1]) {
            size = (w, h)
        }
        guard let (width, height) = size else { return nil }

        let kind: SimulatorDisplay.Kind
        if let type = raw["type"] as? [String: Any], let key = type.keys.sorted().first {
            switch key {
            case "integrated": kind = .integrated
            case "virtual": kind = .virtual
            default: kind = .other(key)
            }
        } else {
            kind = .other("unknown")
        }

        return SimulatorDisplay(
            displayID: UInt32(id),
            uniqueID: uniqueID,
            name: name,
            kind: kind,
            isPrimary: (raw["primary"] as? Bool) ?? false,
            isActive: (raw["active"] as? Bool) ?? false,
            backlightState: raw["backlightState"] as? String,
            rotation: (raw["currentOrientation"] as? String).flatMap(SimulatorDisplayRotation.init(rawValue:)) ?? .rot0,
            pixelWidth: width,
            pixelHeight: height,
            pointScale: DevicectlQuery.number(raw["pointScale"]) ?? 0
        )
    }
}

// MARK: - Monitor (cache)

/// Per-UDID cache in front of `SimulatorDisplayTopologyProbe`, kept in the
/// per-UDID daemon.
///
/// The display set of a device type never changes, so a device seen with
/// one integrated display keeps its first answer for the life of the
/// process: traditional iPhones pay one ~0.1 s probe per daemon, not one per
/// command. A multi-display device can change its active display at any
/// time (fold, hinge, lock), so its answer lives for `ttl` and `fold` /
/// `rotate` invalidate it. `fresh: true` bypasses the cache for callers
/// that need the current rotation.
public actor SimulatorDisplayTopologyMonitor {
    public typealias Probe = @Sendable (String) -> SimulatorDisplayTopologyState

    public static let shared = SimulatorDisplayTopologyMonitor()

    public static let defaultTTL: TimeInterval = 2
    public static let disableEnvironmentKey = "SIM_USE_DISPLAY_TOPOLOGY_CHECK"

    /// The size of an accessibility root, compared by value.
    public struct RootSize: Equatable, Sendable {
        public let width: Double
        public let height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    private struct CacheEntry {
        let state: SimulatorDisplayTopologyState
        let checkedAt: Date
        /// The AX root size the probe was made with, nil when none was offered.
        let rootSize: RootSize?
    }

    private let ttl: TimeInterval
    private let clock: @Sendable () -> Date
    private let probe: Probe
    private let environment: [String: String]
    private var cache: [String: CacheEntry] = [:]
    private var toolUnavailableReason: String?
    private(set) var probeCount = 0

    public init(
        ttl: TimeInterval = SimulatorDisplayTopologyMonitor.defaultTTL,
        clock: @escaping @Sendable () -> Date = { Date() },
        probe: @escaping Probe = { SimulatorDisplayTopologyProbe.run(udid: $0) },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.ttl = ttl
        self.clock = clock
        self.probe = probe
        self.environment = environment
    }

    /// `rootSize` is the size of the AX root a caller just fetched. On a
    /// multi-display device a root size that differs from the one the
    /// cached answer was probed with bypasses that answer: the app moved to
    /// another display (a fold from Device Hub or another process) or its
    /// scene changed shape, inside the TTL (R157-02). The same root size
    /// seen again does not re-probe, and a single-display answer stays
    /// permanent.
    public func state(for udid: String, fresh: Bool = false, rootSize: RootSize? = nil) -> SimulatorDisplayTopologyState {
        if let raw = environment[Self.disableEnvironmentKey]?.lowercased(),
           ["0", "false", "no", "off"].contains(raw)
        {
            return .unavailable(reason: "disabled by \(Self.disableEnvironmentKey)=\(raw)")
        }
        if let reason = toolUnavailableReason {
            return .unavailable(reason: reason)
        }

        let now = clock()
        if !fresh, let entry = cache[udid] {
            if let topology = entry.state.topology, !topology.isMultiDisplay {
                return entry.state
            }
            let rootChanged = rootSize != nil && rootSize != entry.rootSize
            if now.timeIntervalSince(entry.checkedAt) < ttl, !rootChanged {
                return entry.state
            }
        }

        probeCount += 1
        let state = probe(udid)
        if case .unavailable(let reason) = state, reason.contains("subcommand") {
            toolUnavailableReason = reason
        }
        cache[udid] = CacheEntry(state: state, checkedAt: now, rootSize: rootSize ?? Self.carriedRootSize(from: cache[udid], to: state))
        return state
    }

    /// The root size a probe without one keeps from the previous entry: only
    /// while the active display and its rotation are unchanged, since the
    /// root size describes that display. A probe that sees another active
    /// display drops it, so the next root size re-probes (R157-02).
    private static func carriedRootSize(from previous: CacheEntry?, to state: SimulatorDisplayTopologyState) -> RootSize? {
        guard let previous, let rootSize = previous.rootSize,
              let old = previous.state.topology?.activeIntegrated,
              let new = state.topology?.activeIntegrated,
              old.uniqueID == new.uniqueID, old.rotation == new.rotation
        else { return nil }
        return rootSize
    }

    /// Drops the cached answer for `udid` so the next query re-probes.
    public func invalidate(udid: String) {
        cache[udid] = nil
    }
}
