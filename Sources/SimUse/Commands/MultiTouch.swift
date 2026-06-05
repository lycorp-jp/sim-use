// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `multi-touch` verb. Owns the verb-specific
/// flag surface, resolves the target platform via `PlatformRouter`,
/// then delegates to `IOSSimMultiTouchCommand` (iOS Simulator) or
/// `AndroidMultiTouchCommand.performMultiTouch` (adb serial).
///
/// `multi-touch` is the raw-coordinate escape hatch for two-finger
/// gestures. High-level verbs (`tap --fingers 2`, `long-press
/// --fingers 2`, `gesture pinch-* / rotate-*`) reuse the same primitive
/// with different trajectory math. Reach for this verb when the
/// available presets don't capture the gesture you need.
struct MultiTouch: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimMultiTouchCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        commandName: "multi-touch",
        abstract: "Dispatch a two-finger gesture with explicit start / end positions for each finger.",
        discussion: """
        Sends a simultaneous two-finger Down at (--x1, --y1) /
        (--x2, --y2), an interpolated trajectory toward
        (--x1-end, --y1-end) / (--x2-end, --y2-end), then a
        simultaneous Up at the end positions. Same primitive used by
        `tap --fingers 2`, `long-press --fingers 2`, and the pinch /
        rotate `gesture` presets — exposed here for cases the higher-
        level verbs don't cover (asymmetric two-finger pan, scripted
        flows, etc.).

        `start == end` (zero net displacement) reproduces the
        two-finger tap / long-press behavior; prefer the typed forms
        in scripts.

        `--steps` and `--step-ms` are iOS-HID-specific (controlling
        Move-event granularity) and silently ignored on Android, where
        `dispatchGesture` interpolates the stroke internally.

        Examples:
          # Pinch-zoom out by moving two fingers apart vertically.
          sim-use multi-touch \\
            --x1 195 --y1 422 --x2 195 --y2 422 \\
            --x1-end 195 --y1-end 222 --x2-end 195 --y2-end 622 \\
            --duration 0.4 --udid SIMULATOR_UDID

          # Two-finger tap (start == end).
          sim-use multi-touch \\
            --x1 195 --y1 422 --x2 195 --y2 522 \\
            --x1-end 195 --y1-end 422 --x2-end 195 --y2-end 522 \\
            --steps 1 --step-ms 50 --udid SIMULATOR_UDID
        """
    )

    @Option(name: .customLong("x1"), help: "First finger start X (pixels).")
    var x1: Double

    @Option(name: .customLong("y1"), help: "First finger start Y (pixels).")
    var y1: Double

    @Option(name: .customLong("x2"), help: "Second finger start X (pixels).")
    var x2: Double

    @Option(name: .customLong("y2"), help: "Second finger start Y (pixels).")
    var y2: Double

    @Option(name: .customLong("x1-end"), help: "First finger end X (pixels).")
    var x1End: Double

    @Option(name: .customLong("y1-end"), help: "First finger end Y (pixels).")
    var y1End: Double

    @Option(name: .customLong("x2-end"), help: "Second finger end X (pixels).")
    var x2End: Double

    @Option(name: .customLong("y2-end"), help: "Second finger end Y (pixels).")
    var y2End: Double

    @Option(name: .customLong("duration"), help: "Gesture duration in seconds. Default 0.5. Honoured directly on Android; on iOS the wall-clock is the product of --steps × --step-ms when --step-ms is supplied explicitly.")
    var duration: Double = 0.5

    @Option(name: .customLong("steps"), help: "iOS-HID Move-event count between Down and Up. Default 10. Silently ignored on Android.")
    var steps: Int = 10

    @Option(name: .customLong("step-ms"), help: "Sleep between iOS-HID Move events (ms). Default derived from --duration / --steps. Silently ignored on Android.")
    var stepMs: Int?

    @Option(name: .customLong("pre-delay"), help: "Delay before the gesture in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after the gesture in seconds.")
    var postDelay: Double?

    @OptionGroup var device: DeviceOptions

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    func format(_ result: ExecutionResult) -> CommandOutput {
        .line("✓ multi-touch (\(x1),\(y1))/(\(x2),\(y2)) → (\(x1End),\(y1End))/(\(x2End),\(y2End)) completed")
    }

    func validate() throws {
        try IOSSimMultiTouchCommand.validateOptions(
            steps: steps,
            stepMs: stepMs,
            duration: duration,
            preDelay: preDelay,
            postDelay: postDelay
        )
    }

    func execute() async throws -> ExecutionResult {
        switch PlatformRouter.resolve(udid: device.resolved) {
        case .android:
            return try await executeAndroid()
        case .iOSSim, .none:
            return try await executeIOSSim()
        }
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        var sub = IOSSimMultiTouchCommand()
        sub.x1 = x1
        sub.y1 = y1
        sub.x2 = x2
        sub.y2 = y2
        sub.x1End = x1End
        sub.y1End = y1End
        sub.x2End = x2End
        sub.y2End = y2End
        sub.duration = duration
        sub.steps = steps
        // Carry --step-ms verbatim; the iOS sub-command derives the
        // per-step sleep from --duration / --steps when this is nil.
        sub.stepMs = stepMs
        sub.preDelay = preDelay
        sub.postDelay = postDelay
        sub.device = device
        sub.json = json
        return try await sub.execute()
    }

    private func executeAndroid() async throws -> ExecutionResult {
        if let preDelay, preDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(preDelay * 1_000_000_000))
        }
        try AndroidMultiTouchCommand.performMultiTouch(
            udid: device.resolved,
            startP1: (x1, y1),
            startP2: (x2, y2),
            endP1: (x1End, y1End),
            endP2: (x2End, y2End),
            duration: duration,
            preDelay: nil,
            postDelay: nil
        )
        if let postDelay, postDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(postDelay * 1_000_000_000))
        }
        return ExecutionResult()
    }
}