// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android multi-touch` — two-stroke parallel `/gesture`
/// dispatch via `AccessibilityService.dispatchGesture`. Mirrors the
/// iOS verb's surface so the top-level cross-platform `multi-touch`
/// forwarder routes here with identical flag shapes.
///
/// `--steps` and `--step-ms` are iOS-HID-specific and silently
/// ignored on Android; `dispatchGesture` interpolates the stroke
/// internally given the start / end / duration. Same precedent as
/// `--delta` on `gesture`.
public struct AndroidMultiTouchCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "multi-touch",
        abstract: "Dispatch a two-finger gesture with explicit start / end positions for each finger on Android."
    )

    @OptionGroup public var device: AndroidDeviceOptions

    @Option(name: .customLong("x1"), help: "First finger start X (pixels).")
    public var x1: Double

    @Option(name: .customLong("y1"), help: "First finger start Y (pixels).")
    public var y1: Double

    @Option(name: .customLong("x2"), help: "Second finger start X (pixels).")
    public var x2: Double

    @Option(name: .customLong("y2"), help: "Second finger start Y (pixels).")
    public var y2: Double

    @Option(name: .customLong("x1-end"), help: "First finger end X (pixels).")
    public var x1End: Double

    @Option(name: .customLong("y1-end"), help: "First finger end Y (pixels).")
    public var y1End: Double

    @Option(name: .customLong("x2-end"), help: "Second finger end X (pixels).")
    public var x2End: Double

    @Option(name: .customLong("y2-end"), help: "Second finger end Y (pixels).")
    public var y2End: Double

    @Option(name: .customLong("duration"), help: "Gesture duration in seconds. Default 0.5.")
    public var duration: Double = 0.5

    @Option(name: .customLong("steps"), help: "iOS-only HID granularity flag. Accepted for cross-platform compatibility; ignored on Android.")
    public var steps: Int = 10

    @Option(name: .customLong("step-ms"), help: "iOS-only HID granularity flag. Accepted for cross-platform compatibility; ignored on Android.")
    public var stepMs: Int?

    @Option(name: .customLong("pre-delay"), help: "Delay before the gesture in seconds.")
    public var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after the gesture in seconds.")
    public var postDelay: Double?

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {}}` envelope on success.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public init() {}
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func validate() throws {
        try Self.validateOptions(duration: duration, preDelay: preDelay, postDelay: postDelay)
    }

    public static func validateOptions(duration: Double, preDelay: Double?, postDelay: Double?) throws {
        guard duration > 0 && duration <= 10.0 else {
            throw ValidationError("--duration must be between 0 and 10 seconds.")
        }
        if let preDelay {
            guard preDelay >= 0 && preDelay <= 10.0 else {
                throw ValidationError("--pre-delay must be between 0 and 10 seconds.")
            }
        }
        if let postDelay {
            guard postDelay >= 0 && postDelay <= 10.0 else {
                throw ValidationError("--post-delay must be between 0 and 10 seconds.")
            }
        }
    }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        try Self.performMultiTouch(
            udid: device.resolved,
            startP1: (x1, y1),
            startP2: (x2, y2),
            endP1: (x1End, y1End),
            endP2: (x2End, y2End),
            duration: duration,
            preDelay: preDelay,
            postDelay: postDelay
        )
        return ExecutionResult()
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(stderr: "multi-touch (\(x1),\(y1))/(\(x2),\(y2)) → (\(x1End),\(y1End))/(\(x2End),\(y2End))\n")
    }

    /// Reusable Android multi-touch entry point. Top-level
    /// cross-platform `MultiTouch` forwards here so both
    /// `sim-use android multi-touch` and `sim-use multi-touch` go
    /// through one body. Symmetric to `AndroidTapCommand.performTap`.
    public static func performMultiTouch(
        udid: String,
        startP1: (x: Double, y: Double),
        startP2: (x: Double, y: Double),
        endP1: (x: Double, y: Double),
        endP2: (x: Double, y: Double),
        duration: Double,
        preDelay: Double?,
        postDelay: Double?,
        controller: AndroidDeviceController = AndroidDeviceController()
    ) throws {
        let client = controller.bridge(serial: udid)
        let display = try client.displayInfo()
        try AndroidGestureBounds.assertPointsFit(
            [startP1, startP2, endP1, endP2],
            width: Double(display.width),
            height: Double(display.height),
            context: "multi-touch",
            hint: "reduce the gesture extent or shift the endpoints inside the display."
        )
        let durationMs = max(1, Int((duration * 1000).rounded()))
        let strokes: [BridgeStroke] = [
            .linear(
                startX: startP1.x, startY: startP1.y,
                endX: endP1.x, endY: endP1.y,
                startTime: 0, duration: durationMs
            ),
            .linear(
                startX: startP2.x, startY: startP2.y,
                endX: endP2.x, endY: endP2.y,
                startTime: 0, duration: durationMs
            ),
        ]
        if let preDelay, preDelay > 0 {
            Thread.sleep(forTimeInterval: preDelay)
        }
        try client.gesture(strokes: strokes)
        if let postDelay, postDelay > 0 {
            Thread.sleep(forTimeInterval: postDelay)
        }
    }
}