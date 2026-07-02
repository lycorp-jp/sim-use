// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android swipe` — single-stroke gesture.
///
/// Flag surface mirrors the top-level cross-platform `sim-use swipe`
/// verb (`--start-x`/`--start-y`/`--end-x`/`--end-y`, `--duration`
/// in seconds, optional `--pre-delay`/`--post-delay`) so an agent that
/// already speaks the top-level form can drop `android` in front
/// without re-learning the argument shape.
///
public struct AndroidSwipeCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "swipe",
        abstract: "Swipe between two coordinates on the Android device."
    )

    @OptionGroup public var device: AndroidDeviceOptions

    @Argument(help: ArgumentHelp(
        "Optional positional coordinate pairs: <from x,y> <to x,y>. Exclusive with --from/--to and --start-x/--start-y/--end-x/--end-y.",
        valueName: "x,y"
    ))
    public var coordinatePairs: [CoordinatePair] = []

    @Option(name: .customLong("from"), help: ArgumentHelp("Starting coordinate pair.", valueName: "x,y"))
    public var from: CoordinatePair?

    @Option(name: .customLong("to"), help: ArgumentHelp("Ending coordinate pair.", valueName: "x,y"))
    public var to: CoordinatePair?

    @Option(name: .customLong("start-x"), help: "The X coordinate of the starting point (pixels).")
    public var startX: Double?

    @Option(name: .customLong("start-y"), help: "The Y coordinate of the starting point (pixels).")
    public var startY: Double?

    @Option(name: .customLong("end-x"), help: "The X coordinate of the end point (pixels).")
    public var endX: Double?

    @Option(name: .customLong("end-y"), help: "The Y coordinate of the end point (pixels).")
    public var endY: Double?

    @Option(name: .customLong("duration"), help: "Duration of the swipe in seconds (default 0.3).")
    public var duration: Double = 0.3

    @Option(name: .customLong("pre-delay"), help: "Delay before starting the swipe in seconds.")
    public var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after completing the swipe in seconds.")
    public var postDelay: Double?

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {}}` envelope on success.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public init() {}
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func validate() throws {
        _ = try resolvedCoordinates()
        guard duration >= 0 else {
            throw ValidationError("--duration must be non-negative.")
        }
        if let preDelay, preDelay < 0 {
            throw ValidationError("--pre-delay must be non-negative.")
        }
        if let postDelay, postDelay < 0 {
            throw ValidationError("--post-delay must be non-negative.")
        }
    }

    public func resolvedCoordinates() throws -> SwipeCoordinates {
        try SwipeCoordinateResolver.resolve(
            startX: startX, startY: startY,
            endX: endX, endY: endY,
            from: from, to: to,
            positional: coordinatePairs
        )
    }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let coords = try resolvedCoordinates()
        if let preDelay, preDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(preDelay * 1_000_000_000))
        }
        let sx = Int(coords.startX.rounded())
        let sy = Int(coords.startY.rounded())
        let ex = Int(coords.endX.rounded())
        let ey = Int(coords.endY.rounded())
        let durationMs = max(1, Int((duration * 1000).rounded()))
        try Self.performSwipe(
            udid: device.resolved,
            startX: sx, startY: sy,
            endX: ex, endY: ey,
            durationMs: durationMs
        )
        if let postDelay, postDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(postDelay * 1_000_000_000))
        }
        return ExecutionResult()
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        guard let coords = try? resolvedCoordinates() else {
            return CommandOutput(stdout: "✓ Swipe completed successfully\n")
        }
        let sx = Int(coords.startX.rounded())
        let sy = Int(coords.startY.rounded())
        let ex = Int(coords.endX.rounded())
        let ey = Int(coords.endY.rounded())
        let durationMs = max(1, Int((duration * 1000).rounded()))
        return CommandOutput(
            stdout: "✓ Swipe (\(sx),\(sy)) → (\(ex),\(ey)) completed successfully\n",
            stderr: "swipe (\(sx),\(sy)) → (\(ex),\(ey)) duration=\(durationMs)ms\n"
        )
    }

    /// Reusable Android swipe entry point. Top-level cross-platform
    /// `Swipe` forwards here for Android UDIDs so both
    /// `sim-use android swipe` and `sim-use swipe` go through one body.
    /// Symmetric to `AndroidTapCommand.performTap`.
    public static func performSwipe(
        udid: String,
        startX: Int,
        startY: Int,
        endX: Int,
        endY: Int,
        durationMs: Int,
        controller: AndroidDeviceController = AndroidDeviceController()
    ) throws {
        let client = controller.bridge(serial: udid)
        try client.swipe(startX: startX, startY: startY, endX: endX, endY: endY, durationMs: durationMs)
    }
}
