// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import SimUseCore

/// iOS Simulator backend for the `gesture` verb. Mirrors the flag
/// surface of top-level `Gesture` and is also reachable directly as
/// `sim-use ios gesture`. The top-level command resolves the target
/// platform via `PlatformRouter` and forwards iOS UDIDs through here.
public struct IOSSimGestureCommand: SimUseExecutableCommand {
    public struct ExecutionResult: Codable {
        public init() {}
    }

    public static let configuration = CommandConfiguration(
        commandName: "gesture",
        abstract: "Perform preset gesture patterns on the iOS Simulator.",
        discussion: """
        Execute common gesture patterns without specifying coordinates.

        Single-finger presets:
          scroll-up, scroll-down, scroll-left, scroll-right
          swipe-from-left-edge, swipe-from-right-edge
          swipe-from-top-edge, swipe-from-bottom-edge

        Two-finger presets (use --scale / --angle / --center-x /
        --center-y / --radius to control geometry; --delta is ignored):
          pinch-in, pinch-out, rotate-cw, rotate-ccw
        """
    )

    @Argument(help: "The gesture preset to perform.")
    public var preset: GesturePreset

    @Option(name: .customLong("screen-width"), help: "Screen width in points (default: 390 for iPhone 15).")
    public var screenWidth: Double?

    @Option(name: .customLong("screen-height"), help: "Screen height in points (default: 844 for iPhone 15).")
    public var screenHeight: Double?

    @Option(name: .customLong("duration"), help: "Duration of the gesture in seconds (uses preset default if not specified).")
    public var duration: Double?

    @Option(name: .customLong("delta"), help: "Distance between touch points in pixels for single-finger presets (uses preset default if not specified). Ignored for pinch / rotate presets.")
    public var delta: Double?

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

    @Option(name: .customLong("steps"), help: "Number of interpolated HID Move events between Down and Up for multi-touch presets. Default 10. Ignored for single-finger presets.")
    public var steps: Int = 10

    @Option(name: .customLong("step-ms"), help: "Sleep between Move events in milliseconds for multi-touch presets. Default derived from --duration / --steps. Ignored for single-finger presets.")
    public var stepMs: Int?

    @Option(name: .customLong("pre-delay"), help: "Delay before starting the gesture in seconds.")
    public var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after completing the gesture in seconds.")
    public var postDelay: Double?

    @OptionGroup public var device: DeviceOptions

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func format(_ result: ExecutionResult) -> CommandOutput { .empty }

    public func validate() throws {
        try Self.validateOptions(
            preset: preset,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            duration: duration,
            delta: delta,
            scale: scale,
            angle: angle,
            centerX: centerX,
            centerY: centerY,
            radius: radius,
            steps: steps,
            stepMs: stepMs,
            preDelay: preDelay,
            postDelay: postDelay
        )
    }

    /// Thin shim over `GesturePreset.validateOptions` so existing
    /// callers (top-level `Gesture` forwarder, tests) keep working
    /// after the validation body moved into SimUseCore for
    /// cross-backend reuse.
    public static func validateOptions(
        preset: GesturePreset,
        screenWidth: Double?,
        screenHeight: Double?,
        duration: Double?,
        delta: Double?,
        scale: Double?,
        angle: Double?,
        centerX: Double?,
        centerY: Double?,
        radius: Double?,
        steps: Int,
        stepMs: Int?,
        preDelay: Double?,
        postDelay: Double?
    ) throws {
        try GesturePreset.validateOptions(
            preset: preset,
            screenWidth: screenWidth, screenHeight: screenHeight,
            duration: duration, delta: delta,
            scale: scale, angle: angle,
            centerX: centerX, centerY: centerY, radius: radius,
            steps: steps, stepMs: stepMs,
            preDelay: preDelay, postDelay: postDelay
        )
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let width = screenWidth ?? 390.0
        let height = screenHeight ?? 844.0
        // `recommendedDuration` auto-extends rotate sweeps beyond 90°
        // to keep angular velocity near 180°/sec (recogniser sweet
        // spot). Pinch / scroll / edge presets fall through to the
        // baseline `defaultDuration` unchanged.
        let gestureDuration = duration ?? preset.recommendedDuration(angle: angle)

        logger.info().log("Performing \(preset.description)")
        logger.info().log("Screen size: \(width)x\(height)")
        logger.info().log("Duration: \(gestureDuration)s")

        if preset.isMultiTouch {
            try await runMultiTouch(
                width: width,
                height: height,
                duration: gestureDuration,
                logger: logger
            )
        } else {
            try await runSingleTouch(
                width: width,
                height: height,
                duration: gestureDuration,
                logger: logger
            )
        }

        logger.info().log("Gesture completed successfully")
        return ExecutionResult()
    }

    private func runSingleTouch(width: Double, height: Double, duration: Double, logger: SimUseLogger) async throws {
        let coords = preset.coordinates(screenWidth: width, screenHeight: height)
        let gestureDelta = delta ?? preset.defaultDelta
        logger.info().log("Coordinates: (\(coords.startX), \(coords.startY)) to (\(coords.endX), \(coords.endY))")
        logger.info().log("Delta: \(gestureDelta)px")

        var events: [FBSimulatorHIDEvent] = []
        if let preDelay, preDelay > 0 {
            events.append(FBSimulatorHIDEvent.delay(preDelay))
        }
        events.append(FBSimulatorHIDEvent.swipe(
            coords.startX,
            yStart: coords.startY,
            xEnd: coords.endX,
            yEnd: coords.endY,
            delta: gestureDelta,
            duration: duration
        ))
        if let postDelay, postDelay > 0 {
            events.append(FBSimulatorHIDEvent.delay(postDelay))
        }
        let finalEvent = events.count == 1 ? events[0] : FBSimulatorHIDEvent(events: events)
        try await HIDInteractor.performHIDEvent(finalEvent, for: device.resolved, logger: logger)
    }

    private func runMultiTouch(width: Double, height: Double, duration: Double, logger: SimUseLogger) async throws {
        let presetStrokes = preset.strokes(
            screenWidth: width,
            screenHeight: height,
            scale: scale,
            angle: angle,
            centerX: centerX,
            centerY: centerY,
            radius: radius
        )
        guard presetStrokes.count == 2 else {
            throw CLIError(errorDescription: "Multi-touch preset \(preset.rawValue) produced \(presetStrokes.count) strokes; expected 2.")
        }
        let f1 = presetStrokes[0]
        let f2 = presetStrokes[1]
        // Spread the user-supplied (or default) duration evenly across
        // the requested step count when --step-ms is omitted, so the
        // total Down→Up wall-clock matches `--duration`. Each gap is
        // floor(duration * 1000 / steps); rounding errors land in the
        // final hold which is fine for recognisers (they accept slight
        // jitter).
        let resolvedStepMs: Int
        if let stepMs {
            resolvedStepMs = stepMs
        } else {
            resolvedStepMs = max(1, Int((duration * 1000.0 / Double(steps)).rounded()))
        }

        logger.info().log("Multi-touch preset \(preset.rawValue) — finger1 (\(f1.startX),\(f1.startY))→(\(f1.endX),\(f1.endY)) finger2 (\(f2.startX),\(f2.startY))→(\(f2.endX),\(f2.endY)) steps=\(steps) step-ms=\(resolvedStepMs)")

        let session = try await HIDInteractor.makeSession(for: device.resolved, logger: logger)
        if let preDelay, preDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(preDelay * 1_000_000_000))
        }
        try await MultiTouchDispatcher.run(
            session: session,
            startP1: (x: f1.startX, y: f1.startY),
            startP2: (x: f2.startX, y: f2.startY),
            steps: steps,
            stepMs: resolvedStepMs,
            interpolate: { t in
                let p1 = f1.point(at: t)
                let p2 = f2.point(at: t)
                return ((x: p1.x, y: p1.y), (x: p2.x, y: p2.y))
            },
            logger: logger
        )
        if let postDelay, postDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(postDelay * 1_000_000_000))
        }
    }
}