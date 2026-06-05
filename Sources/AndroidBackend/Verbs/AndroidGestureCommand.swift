// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android gesture` — preset gesture pattern dispatched
/// through the bridge's `/swipe` endpoint (which is itself backed by
/// `AccessibilityService.dispatchGesture`, the right primitive for
/// single-finger linear strokes).
///
/// Mirrors the iOS `gesture` verb on the Android side; the cross-
/// platform top-level `gesture` forwards here for Android UDIDs.
public struct AndroidGestureCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "gesture",
        abstract: "Perform a preset gesture pattern on the Android device."
    )

    @OptionGroup public var device: AndroidDeviceOptions

    @Argument(help: "The gesture preset to perform.")
    public var preset: GesturePreset

    @Option(name: .customLong("screen-width"), help: "Screen width in pixels. Optional — defaults to the bridge's reported display width.")
    public var screenWidth: Double?

    @Option(name: .customLong("screen-height"), help: "Screen height in pixels. Optional — defaults to the bridge's reported display height.")
    public var screenHeight: Double?

    @Option(name: .customLong("duration"), help: "Duration of the gesture in seconds (uses preset default if not specified).")
    public var duration: Double?

    @Option(name: .customLong("scale"), help: "Pinch scale ratio (end radius / start radius). Defaults: 2.0 for pinch-out, 0.5 for pinch-in. Ignored for non-pinch presets.")
    public var scale: Double?

    @Option(name: .customLong("angle"), help: "Rotation sweep in degrees for rotate-cw / rotate-ccw. Default 90.0. Ignored for non-rotate presets.")
    public var angle: Double?

    @Option(name: .customLong("center-x"), help: "Pivot X for pinch / rotate presets (pixels). Defaults to screen center.")
    public var centerX: Double?

    @Option(name: .customLong("center-y"), help: "Pivot Y for pinch / rotate presets (pixels). Defaults to screen center.")
    public var centerY: Double?

    @Option(name: .customLong("radius"), help: "Start radius for pinch / rotate presets (pixels). Default 80.")
    public var radius: Double?

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {}}` envelope on success.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public init() {}
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func validate() throws {
        // Same rules as the iOS sub-command and the top-level
        // forwarder — `--scale` only on pinch presets, `--angle`
        // only on rotate, range checks on the geometry knobs.
        // Without this, `sim-use android gesture pinch-out --angle 90`
        // would slip past argument parsing and only surface as a
        // generic display-bounds error (when at all). `--steps` /
        // `--step-ms` aren't exposed on this verb (they're iOS-HID
        // specific), so we pass the harmless defaults to the shared
        // validator.
        try GesturePreset.validateOptions(
            preset: preset,
            screenWidth: screenWidth, screenHeight: screenHeight,
            duration: duration, delta: nil,
            scale: scale, angle: angle,
            centerX: centerX, centerY: centerY, radius: radius,
            steps: 1, stepMs: nil,
            preDelay: nil, postDelay: nil
        )
    }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        try Self.performGesture(
            udid: device.resolved,
            preset: preset,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            duration: duration,
            scale: scale,
            angle: angle,
            centerX: centerX,
            centerY: centerY,
            radius: radius,
            preDelay: nil,
            postDelay: nil
        )
        return ExecutionResult()
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(stderr: "gesture \(preset.rawValue)\n")
    }

    /// Reusable Android gesture entry point. Top-level cross-platform
    /// `Gesture` forwards here for Android UDIDs so both
    /// `sim-use android gesture` and `sim-use gesture` go through one
    /// body. Symmetric to `AndroidTapCommand.performTap`.
    ///
    /// Screen-size resolution order:
    ///   1. explicit `screenWidth` / `screenHeight` arguments
    ///   2. bridge-reported display (cached real device pixels)
    /// We do NOT fall back to iOS's 390×844 — Android resolutions vary
    /// too widely for a fixed default to be sensible.
    ///
    /// `--delta` is iOS-HID-specific and intentionally absent here;
    /// `dispatchGesture` interpolates the stroke internally.
    ///
    /// `preDelay` / `postDelay` are exposed for the cross-platform
    /// forwarder to honour. They are run synchronously via
    /// `Thread.sleep` in this static so the entry point stays
    /// non-async; the forwarder's async wrapper uses `Task.sleep`
    /// when called from an async context. (Both shapes block the
    /// calling task — Thread.sleep here is fine because each
    /// preDelay/postDelay is also bounded ≤10s by the shared
    /// validator.)
    public static func performGesture(
        udid: String,
        preset: GesturePreset,
        screenWidth: Double?,
        screenHeight: Double?,
        duration: Double?,
        scale: Double? = nil,
        angle: Double? = nil,
        centerX: Double? = nil,
        centerY: Double? = nil,
        radius: Double? = nil,
        preDelay: Double?,
        postDelay: Double?,
        controller: AndroidDeviceController = AndroidDeviceController()
    ) throws {
        let client = controller.bridge(serial: udid)

        let width: Double
        let height: Double
        if let screenWidth, let screenHeight {
            width = screenWidth
            height = screenHeight
        } else {
            let display = try client.displayInfo()
            width = Double(display.width)
            height = Double(display.height)
        }

        // Match the iOS path: rotate sweeps auto-extend their default
        // duration to keep angular velocity at ~180°/sec. Pinch and
        // single-finger presets stay at `defaultDuration`.
        let gestureDuration = duration ?? preset.recommendedDuration(angle: angle)
        let durationMs = max(1, Int((gestureDuration * 1000).rounded()))

        if let preDelay, preDelay > 0 {
            Thread.sleep(forTimeInterval: preDelay)
        }

        if preset.isMultiTouch {
            let presetStrokes = preset.strokes(
                screenWidth: width, screenHeight: height,
                scale: scale, angle: angle,
                centerX: centerX, centerY: centerY,
                radius: radius
            )
            try Self.assertStrokesFitDisplay(presetStrokes, width: width, height: height, preset: preset)
            let bridgeStrokes: [BridgeStroke] = presetStrokes.map { stroke in
                switch stroke.curve {
                case .linear:
                    return .linear(
                        startX: stroke.startX, startY: stroke.startY,
                        endX: stroke.endX, endY: stroke.endY,
                        startTime: 0, duration: durationMs
                    )
                case .arc:
                    // Sample the arc into a polyline. 16 waypoints
                    // (`arcWaypointCount`) hold the radius within
                    // <2% of the true circle for sweeps up to 360°
                    // and dispatch cleanly through Android's
                    // GestureDescription.Path renderer. The bridge
                    // walks the polyline at constant time per segment.
                    let waypoints: [BridgeStrokePoint] = (0...arcWaypointCount).map { i in
                        let t = Double(i) / Double(arcWaypointCount)
                        let p = stroke.point(at: t)
                        return BridgeStrokePoint(x: p.x, y: p.y)
                    }
                    return .polyline(points: waypoints, startTime: 0, duration: durationMs)
                }
            }
            try client.gesture(strokes: bridgeStrokes)
        } else {
            let coords = preset.coordinates(screenWidth: width, screenHeight: height)
            try client.swipe(
                startX: Int(coords.startX.rounded()),
                startY: Int(coords.startY.rounded()),
                endX: Int(coords.endX.rounded()),
                endY: Int(coords.endY.rounded()),
                durationMs: durationMs
            )
        }

        if let postDelay, postDelay > 0 {
            Thread.sleep(forTimeInterval: postDelay)
        }
    }

    /// Number of polyline segments used to approximate an arc stroke
    /// when dispatching rotate presets through the bridge. 16 segments
    /// keep the max radial deviation under ~2% of the configured
    /// radius across sweeps up to a full circle, which is well below
    /// what touch recognisers can resolve.
    private static let arcWaypointCount = 16

    public static func assertStrokesFitDisplay(
        _ strokes: [GesturePreset.Stroke],
        width: Double,
        height: Double,
        preset: GesturePreset
    ) throws {
        // Sample every endpoint and a few arc waypoints so the bbox
        // catches rotates whose mid-trajectory escapes the display
        // even when start/end are on-screen.
        var points: [(Double, Double)] = []
        for stroke in strokes {
            switch stroke.curve {
            case .linear:
                points.append((stroke.startX, stroke.startY))
                points.append((stroke.endX, stroke.endY))
            case .arc:
                for i in 0...4 {
                    let p = stroke.point(at: Double(i) / 4.0)
                    points.append((p.x, p.y))
                }
            }
        }
        let hint: String
        switch preset {
        case .pinchIn, .pinchOut:
            hint = "reduce --scale or --radius, or move --center-x / --center-y away from the edge."
        case .rotateCw, .rotateCcw:
            hint = "reduce --radius, or move --center-x / --center-y away from the edge."
        default:
            hint = "reduce the gesture extent."
        }
        try AndroidGestureBounds.assertPointsFit(
            points,
            width: width, height: height,
            context: preset.rawValue,
            hint: hint
        )
    }
}

/// Display-bounds enforcement shared by `AndroidGestureCommand` (pinch /
/// rotate presets), `AndroidMultiTouchCommand` (raw two-finger
/// trajectories), and `AndroidTapCommand` (when `--fingers 2`).
///
/// Android's `GestureDescription.StrokeDescription` constructor rejects
/// any Path whose bounds escape the display, and the bridge surfaces
/// that as `Path bounds must not be negative` — opaque from the
/// caller's point of view. Catching the violation Swift-side lets us
/// return the actual offending geometry plus an actionable hint, which
/// agents can act on directly. iOS has no equivalent constraint; its
/// HID layer happily accepts off-screen points, so this check lives in
/// the Android path only.
enum AndroidGestureBounds {
    static func assertPointsFit(
        _ points: [(x: Double, y: Double)],
        width: Double,
        height: Double,
        context: String,
        hint: String
    ) throws {
        guard !points.isEmpty else { return }
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for (x, y) in points {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        let displayMaxX = width - 1
        let displayMaxY = height - 1
        guard minX >= 0, minY >= 0, maxX <= displayMaxX, maxY <= displayMaxY else {
            let xRange = String(format: "[%.0f, %.0f]", minX, maxX)
            let yRange = String(format: "[%.0f, %.0f]", minY, maxY)
            let displaySize = String(format: "%.0fx%.0f", width, height)
            throw CLIError(errorDescription:
                "\(context) endpoints lie outside display \(displaySize): x in \(xRange), y in \(yRange). \(hint)"
            )
        }
    }
}