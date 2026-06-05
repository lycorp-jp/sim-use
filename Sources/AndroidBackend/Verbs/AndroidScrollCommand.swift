// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android scroll` — convenience wrapper for vertical/horizontal
/// scrolling. Internally just `/swipe` with computed start/end.
public struct AndroidScrollCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "scroll",
        abstract: "Scroll a region by direction + amount."
    )

    public enum Direction: String, ExpressibleByArgument, CaseIterable {
        case up, down, left, right
    }

    @OptionGroup public var device: AndroidDeviceOptions

    @Option(name: .customLong("direction"), help: "up | down | left | right.")
    public var direction: Direction

    @Option(name: .customLong("center"), help: "Pivot center as x,y. Defaults to screen center (calls describe-ui to discover).")
    public var center: String?

    @Option(name: .customLong("distance"), help: "Pixel distance to drag (default 800).")
    public var distance: Int = 800

    @Option(name: .customLong("duration"), help: "Gesture duration in milliseconds (default 400).")
    public var durationMs: Int = 400

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {startX, startY, endX, endY}}` envelope on success.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let startX: Int
        public let startY: Int
        public let endX: Int
        public let endY: Int
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let controller = AndroidDeviceController()
        let (cx, cy): (Int, Int)
        if let center {
            (cx, cy) = try parsePoint(center, flag: "--center")
        } else {
            // Cheap: ping + 1 describe-ui to discover the screen extents.
            let result = try controller.describeUI(serial: device.resolved)
            cx = result.screen.width / 2
            cy = result.screen.height / 2
        }
        let half = max(1, distance / 2)
        // Convention: `--direction down` means the user wants to see
        // content further down the list, which requires the FINGER to
        // drag upward (start low, end high → small y). Same as the
        // physical scroll gesture you'd make on a real phone.
        let (sx, sy, ex, ey): (Int, Int, Int, Int)
        switch direction {
        case .down:  (sx, sy, ex, ey) = (cx, cy + half, cx, cy - half)
        case .up:    (sx, sy, ex, ey) = (cx, cy - half, cx, cy + half)
        case .right: (sx, sy, ex, ey) = (cx + half, cy, cx - half, cy)
        case .left:  (sx, sy, ex, ey) = (cx - half, cy, cx + half, cy)
        }
        let client = controller.bridge(serial: device.resolved)
        try client.swipe(startX: sx, startY: sy, endX: ex, endY: ey, durationMs: durationMs)
        return ExecutionResult(startX: sx, startY: sy, endX: ex, endY: ey)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(
            stdout: "✓ Scroll \(direction.rawValue) completed successfully\n",
            stderr: "scroll \(direction.rawValue) (\(result.startX),\(result.startY)) → (\(result.endX),\(result.endY))\n"
        )
    }
}