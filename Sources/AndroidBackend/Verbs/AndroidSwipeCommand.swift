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
/// The legacy `--from x,y` / `--to x,y` / millisecond `--duration`
/// shape that 0.5.x shipped is rejected at validate time with a
/// pointer to the new flags.
public struct AndroidSwipeCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "swipe",
        abstract: "Swipe between two coordinates on the Android device."
    )

    @OptionGroup public var device: AndroidDeviceOptions

    @Option(name: .customLong("start-x"), help: "The X coordinate of the starting point (pixels).")
    public var startX: Double

    @Option(name: .customLong("start-y"), help: "The Y coordinate of the starting point (pixels).")
    public var startY: Double

    @Option(name: .customLong("end-x"), help: "The X coordinate of the end point (pixels).")
    public var endX: Double

    @Option(name: .customLong("end-y"), help: "The Y coordinate of the end point (pixels).")
    public var endY: Double

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

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        if let preDelay, preDelay > 0 {
            Thread.sleep(forTimeInterval: preDelay)
        }
        let sx = Int(startX.rounded())
        let sy = Int(startY.rounded())
        let ex = Int(endX.rounded())
        let ey = Int(endY.rounded())
        let durationMs = max(1, Int((duration * 1000).rounded()))
        try Self.performSwipe(
            udid: device.resolved,
            startX: sx, startY: sy,
            endX: ex, endY: ey,
            durationMs: durationMs
        )
        if let postDelay, postDelay > 0 {
            Thread.sleep(forTimeInterval: postDelay)
        }
        return ExecutionResult()
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        let sx = Int(startX.rounded())
        let sy = Int(startY.rounded())
        let ex = Int(endX.rounded())
        let ey = Int(endY.rounded())
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