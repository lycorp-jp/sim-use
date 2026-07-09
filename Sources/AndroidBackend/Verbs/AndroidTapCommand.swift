// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android tap` — resolves a target on the device's last
/// `describe-ui` snapshot (via `OutlineCache`) or via selector flags
/// against a fresh snapshot, then dispatches `/tap` at the element's
/// own center (no walk-up, per kickoff gotcha #4).
///
/// Coordinate fallback (`-x`/`-y`) is provided for ad-hoc / cross-test
/// use; selector-based addressing is preferred.
public struct AndroidTapCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tap",
        abstract: "Tap an element on the Android device by alias, selector, or coordinate."
    )

    @OptionGroup public var device: AndroidDeviceOptions

    @Argument(help: "Positional alias from the last describe-ui snapshot: @N (entry index), #N (dominant list cell), #N@M (list M cell N), or #<unique-id>.")
    public var alias: String?

    @Option(name: [.customShort("x"), .customLong("x")], help: "Tap x coordinate (pixels). Accepts -x or --x. Use with -y/--y; mutually exclusive with selectors.")
    public var x: Int?
    @Option(name: [.customShort("y"), .customLong("y")], help: "Tap y coordinate (pixels). Accepts -y or --y.")
    public var y: Int?

    @Option(name: .customLong("id"), help: "Match uniqueId or resource_id short-name.")
    public var id: String?
    @Option(name: .customLong("label"), help: "Match contentDescription exactly.")
    public var label: String?
    @Option(name: .customLong("label-contains"), help: "Match contentDescription (case-sensitive substring). Use --label-regex with `(?i)` for case-insensitive matching.")
    public var labelContains: String?
    @Option(name: .customLong("label-regex"), help: "Match contentDescription against regex.")
    public var labelRegex: String?
    @Option(name: .customLong("value"), help: "Match text exactly.")
    public var value: String?
    @Option(name: .customLong("value-contains"), help: "Match text (case-sensitive substring). Use --value-regex with `(?i)` for case-insensitive matching.")
    public var valueContains: String?
    @Option(name: .customLong("value-regex"), help: "Match text against regex.")
    public var valueRegex: String?
    @Option(name: .customLong("element-type"), help: "Restrict to a canonical element type (Button, TextField, …).")
    public var elementType: String?

    @Option(
        name: .customLong("duration"),
        help: ArgumentHelp(
            "How long to hold the touch in seconds. Omitted or 0 dispatches the standard one-shot `/tap` (fastest path). Provide a positive value (e.g. 0.8) to hold via `/swipe` with `start=end` — this is how the Android framework observes a long-press."
        )
    )
    public var duration: Double?

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {x, y}}` envelope used by the cross-platform `tap --json`.")
    public var jsonOutput: Bool = false

    public init() {}

    /// Wire shape mirrors `IOSSimTapCommand.ExecutionResult` so the
    /// cross-platform `sim-use tap --json` and `sim-use android tap --json`
    /// emit byte-identical envelopes. Coordinates are widened to
    /// `Double` for that reason — Android natively works in integer
    /// pixels, the cast is lossless. `description` carries the
    /// resolver path (e.g. `alias @4 → "Send"`) for the text-mode
    /// stderr diagnostic; `CodingKeys` excludes it from the JSON
    /// envelope so iOS / Android `--json` outputs stay byte-identical.
    public struct ExecutionResult: Codable {
        public let x: Double
        public let y: Double
        public let description: String

        private enum CodingKeys: String, CodingKey { case x, y }

        public init(x: Double, y: Double, description: String) {
            self.x = x
            self.y = y
            self.description = description
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.x = try container.decode(Double.self, forKey: .x)
            self.y = try container.decode(Double.self, forKey: .y)
            self.description = ""
        }
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func validate() throws {
        if let duration {
            guard duration >= 0 && duration <= 10.0 else {
                throw ValidationError("--duration must be between 0 and 10 seconds.")
            }
        }
    }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let result = try Self.performTap(
            udid: device.resolved,
            alias: alias,
            x: x, y: y,
            selector: selector(),
            duration: duration
        )
        return ExecutionResult(
            x: Double(result.x),
            y: Double(result.y),
            description: result.description
        )
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        // stdout `✓` matches the cross-platform `Tap` / `Button`
        // contract — scripts grep stdout for the marker and treat
        // its presence as success. The descriptive parenthetical
        // stays on stderr where it doesn't pollute machine-parsed
        // pipelines.
        let xi = Int(result.x.rounded())
        let yi = Int(result.y.rounded())
        return CommandOutput(
            stdout: "✓ Tap at (\(xi), \(yi)) completed successfully\n",
            stderr: "tap at (\(xi), \(yi)) [\(result.description)]\n"
        )
    }

    /// Reusable Android tap entry point. The top-level cross-platform
    /// `Tap` command forwards here so both the explicit
    /// `sim-use android tap` and the auto-routed `sim-use tap` go
    /// through one body — symmetric to how `IOSSimTapCommand` is
    /// reused on the iOS side.
    ///
    /// `multiTouch` carries `--fingers` / `--x2` / `--y2` /
    /// `--finger-distance` from the top-level forwarder. When
    /// `fingers == 2`, the dispatch becomes a two-stroke `/gesture`
    /// with both strokes starting at the resolved target / explicit
    /// second-finger placement; otherwise the original single-stroke
    /// path is unchanged. `nil` means single-touch — the parameter is
    /// optional (not a `MultiTouchOptions()` default) because a
    /// directly-initialized `ParsableArguments` value traps on first
    /// property read ("can't read a value from a parsable argument
    /// definition"), which crashed every `sim-use android tap`.
    public static func performTap(
        udid: String,
        alias: String?,
        x: Int?,
        y: Int?,
        selector: AndroidSelector,
        duration: Double? = nil,
        multiTouch: MultiTouchOptions? = nil,
        controller: AndroidDeviceController = AndroidDeviceController()
    ) throws -> (x: Int, y: Int, description: String) {
        let target = try AndroidTargetResolver.resolve(
            udid: udid,
            alias: alias,
            x: x, y: y,
            selector: selector,
            controller: controller
        )
        let client = controller.bridge(serial: udid)
        if let multiTouch, multiTouch.fingers == 2 {
            let finger1 = (x: Double(target.x), y: Double(target.y))
            let finger2 = multiTouch.fingerTwoPoint(forFinger1: finger1)
            let display = try client.displayInfo()
            try AndroidGestureBounds.assertPointsFit(
                [finger1, finger2],
                width: Double(display.width),
                height: Double(display.height),
                context: "tap --fingers 2",
                hint: "shrink --finger-distance, switch to explicit --x2/--y2, or pick a target nearer the centre."
            )
            // Two-finger tap / long-press: both fingers hold at their
            // start positions for `duration` seconds (or a minimal hold
            // for ordinary tap). `start == end` is the same pattern
            // single-finger long-press uses — recogniser sees a real
            // hold instead of a sub-millisecond contact.
            let hold = duration ?? 0.05
            let durationMs = max(1, Int((hold * 1000).rounded()))
            let strokes: [BridgeStroke] = [
                .linear(
                    startX: finger1.x, startY: finger1.y,
                    endX: finger1.x, endY: finger1.y,
                    startTime: 0, duration: durationMs
                ),
                .linear(
                    startX: finger2.x, startY: finger2.y,
                    endX: finger2.x, endY: finger2.y,
                    startTime: 0, duration: durationMs
                ),
            ]
            try client.gesture(strokes: strokes)
        } else if let duration, duration > 0 {
            // `dispatchGesture` is one-shot: a single stroke with
            // `start == end` and a real duration is how Android
            // surfaces a long-press to recognisers. Floor to 1 ms
            // because `StrokeDescription` rejects zero-length time
            // even with degenerate paths.
            let durationMs = max(1, Int((duration * 1000).rounded()))
            try client.swipe(
                startX: target.x, startY: target.y,
                endX: target.x, endY: target.y,
                durationMs: durationMs
            )
        } else {
            try client.tap(x: target.x, y: target.y)
        }
        return (target.x, target.y, target.description)
    }

    private func selector() -> AndroidSelector {
        AndroidSelector(
            id: id,
            label: label,
            labelContains: labelContains,
            labelRegex: labelRegex,
            value: value,
            valueContains: valueContains,
            valueRegex: valueRegex,
            elementType: elementType
        )
    }
}