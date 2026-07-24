// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import SimUseCore

/// `sim-use ios multi-touch` — dispatches an arbitrary two-finger
/// trajectory through upstream's `FBSimulatorHIDEvent.twoFingerTouch`
/// primitive (originally productised from the validation spike on
/// `spike/ios-multi-touch`; the local patch was superseded by the
/// native upstream API in the idb bump).
///
/// The verb is the raw-coordinate escape hatch. High-level verbs
/// (`tap --fingers 2`, `long-press --fingers 2`, `gesture pinch-*` /
/// `gesture rotate-*`) reuse the same primitive with different
/// trajectory math; reach for `multi-touch` when the available presets
/// don't capture the gesture you need (asymmetric pan, scripted
/// two-finger flows, etc.).
///
/// Wire shape: simultaneous Down at the start points → `--steps`
/// interpolated Move events from start to end → simultaneous Up at the
/// end points. `start == end` (zero net displacement) is a valid
/// shortcut to two-finger tap / long-press semantics, but the typed
/// `tap --fingers 2` / `long-press --fingers 2` forms are the
/// ergonomic path.
public struct IOSSimMultiTouchCommand: SimUseExecutableCommand {
    public struct ExecutionResult: Codable {
        public init() {}
    }

    public static let configuration = CommandConfiguration(
        commandName: "multi-touch",
        abstract: "Dispatch a two-finger gesture with explicit start / end positions for each finger.",
        discussion: """
            Sends a simultaneous two-finger Down at (--x1, --y1) / (--x2, --y2),
            then `--steps` linearly interpolated Move events toward
            (--x1-end, --y1-end) / (--x2-end, --y2-end), then a
            simultaneous Up at the end positions. iOS recognises this
            as a continuous two-finger gesture (it keys on finger
            identifier continuity, not event count).

            Examples:
              # Pinch-zoom out by moving two fingers apart along the
              # vertical axis. 195/422 is roughly screen center on an
              # iPhone-15-shaped sim.
              sim-use ios multi-touch \\
                --x1 195 --y1 422 --x2 195 --y2 422 \\
                --x1-end 195 --y1-end 222 --x2-end 195 --y2-end 622 \\
                --duration 0.4 --udid SIMULATOR_UDID

              # Two-finger tap (start == end). Prefer
              # `sim-use tap --fingers 2 -x ... -y ...` in scripts.
              sim-use ios multi-touch \\
                --x1 195 --y1 422 --x2 195 --y2 522 \\
                --x1-end 195 --y1-end 422 --x2-end 195 --y2-end 522 \\
                --steps 1 --step-ms 50 --udid SIMULATOR_UDID
            """
    )

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

    @Option(name: .customLong("duration"), help: "Gesture duration in seconds. Default 0.5. When --step-ms is omitted, the per-Move sleep is derived as duration*1000/steps so total wall-clock matches this value; supplying --step-ms explicitly overrides the derivation.")
    public var duration: Double = 0.5

    @Option(name: .customLong("steps"), help: "Number of interpolated Move events between Down and Up (≥ 1). Default 10.")
    public var steps: Int = 10

    @Option(name: .customLong("step-ms"), help: "Sleep between consecutive Move events in milliseconds. Default derived from --duration / --steps.")
    public var stepMs: Int?

    @Option(name: .customLong("pre-delay"), help: "Delay before the gesture in seconds.")
    public var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after the gesture in seconds.")
    public var postDelay: Double?

    @OptionGroup public var device: DeviceOptions

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func validate() throws {
        try Self.validateOptions(
            steps: steps,
            stepMs: stepMs,
            duration: duration,
            preDelay: preDelay,
            postDelay: postDelay
        )
    }

    public static func validateOptions(
        steps: Int,
        stepMs: Int?,
        duration: Double,
        preDelay: Double?,
        postDelay: Double?
    ) throws {
        guard steps >= 1 else {
            throw ValidationError("--steps must be ≥ 1.")
        }
        if let stepMs {
            guard stepMs >= 0 else {
                throw ValidationError("--step-ms must be ≥ 0.")
            }
        }
        guard duration > 0 && duration <= 10.0 else {
            throw ValidationError("--duration must be between 0 and 10 seconds.")
        }
        if let preDelay {
            guard preDelay >= 0 && preDelay <= 10.0 else {
                throw ValidationError("Pre-delay must be between 0 and 10 seconds.")
            }
        }
        if let postDelay {
            guard postDelay >= 0 && postDelay <= 10.0 else {
                throw ValidationError("Post-delay must be between 0 and 10 seconds.")
            }
        }
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("✓ multi-touch (\(x1),\(y1))/(\(x2),\(y2)) → (\(x1End),\(y1End))/(\(x2End),\(y2End)) completed")
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let session = try await HIDInteractor.makeSession(for: device.resolved, logger: logger)

        if let preDelay, preDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(preDelay * 1_000_000_000))
        }

        // Derive per-step sleep from --duration when --step-ms isn't
        // explicit, so the wall-clock matches what users typed
        // (consistent with the Android sub-command's --duration
        // semantics). Floor at 1 ms so the dispatcher's minimumStepMs
        // (5 ms) still applies.
        let effectiveStepMs = stepMs ?? max(1, Int((duration * 1000.0 / Double(steps)).rounded()))
        try await MultiTouchDispatcher.run(
            session: session,
            start: (p1: (x1, y1), p2: (x2, y2)),
            end: (p1: (x1End, y1End), p2: (x2End, y2End)),
            steps: steps,
            stepMs: effectiveStepMs,
            logger: logger
        )

        if let postDelay, postDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(postDelay * 1_000_000_000))
        }

        return ExecutionResult()
    }
}

/// Shared dispatch helper that the multi-touch verb and the `tap` /
/// `long-press` / `gesture` multi-touch paths all use. Centralised so
/// the Down → N×Move → Up pattern (validated by the spike) lives in one
/// place. Generic on the per-step interpolator so rotate gestures can
/// supply an arc parameterisation without changing the surrounding
/// dispatch shape.
enum MultiTouchDispatcher {

    /// Linear-interpolation entry point. `start` and `end` are
    /// straight-line endpoints; each Move samples the line at
    /// `t = i / steps`.
    static func run(
        session: HIDInteractor.Session,
        start: (p1: (x: Double, y: Double), p2: (x: Double, y: Double)),
        end: (p1: (x: Double, y: Double), p2: (x: Double, y: Double)),
        steps: Int,
        stepMs: Int,
        logger: SimUseLogger
    ) async throws {
        try await run(
            session: session,
            startP1: start.p1, startP2: start.p2,
            steps: steps, stepMs: stepMs,
            interpolate: { t in
                let p1 = (
                    x: start.p1.x + (end.p1.x - start.p1.x) * t,
                    y: start.p1.y + (end.p1.y - start.p1.y) * t
                )
                let p2 = (
                    x: start.p2.x + (end.p2.x - start.p2.x) * t,
                    y: start.p2.y + (end.p2.y - start.p2.y) * t
                )
                return (p1, p2)
            },
            logger: logger
        )
    }

    /// Generic entry point. `interpolate(t)` returns the (finger1,
    /// finger2) positions at progress `t ∈ (0, 1]`. The initial Down
    /// uses the supplied `startP1` / `startP2`; the final Up uses the
    /// last interpolated position so the recogniser sees a clean
    /// trajectory through `interpolate(1.0)`.
    ///
    /// The whole trajectory is assembled into a single `.composite`
    /// event (a Move is a repeated `.down` at the new position — the
    /// same convention upstream's `pinchAt` uses) and sent through
    /// `HIDInteractor.performHIDEvent`, so the transport is drained
    /// exactly once at the end of the gesture. Sending the primitives
    /// individually would skip the per-gesture `flush()` the DTUHID
    /// transport needs.
    static func run(
        session: HIDInteractor.Session,
        startP1: (x: Double, y: Double),
        startP2: (x: Double, y: Double),
        steps: Int,
        stepMs: Int,
        interpolate: (Double) -> ((x: Double, y: Double), (x: Double, y: Double)),
        logger: SimUseLogger
    ) async throws {
        // Empirical (Indigo transport): consecutive touch messages with
        // zero delay in between make SimulatorKit's underlying message
        // builder return nil for the subsequent message. Enforce a 5 ms
        // floor so callers don't need to know about it.
        let effectiveStepMs = max(stepMs, minimumStepMs)
        let stepDelay = TimeInterval(effectiveStepMs) / 1000.0

        var events: [FBSimulatorHIDEvent] = []
        events.append(.twoFingerTouch(
            direction: .down,
            finger1: CGPoint(x: startP1.x, y: startP1.y),
            finger2: CGPoint(x: startP2.x, y: startP2.y)
        ))

        var lastP1 = startP1
        var lastP2 = startP2
        let safeSteps = max(steps, 1)
        for i in 1...safeSteps {
            let t = Double(i) / Double(safeSteps)
            let (p1, p2) = interpolate(t)
            events.append(.delay(stepDelay))
            events.append(.twoFingerTouch(
                direction: .down,
                finger1: CGPoint(x: p1.x, y: p1.y),
                finger2: CGPoint(x: p2.x, y: p2.y)
            ))
            lastP1 = p1
            lastP2 = p2
        }
        events.append(.delay(stepDelay))
        events.append(.twoFingerTouch(
            direction: .up,
            finger1: CGPoint(x: lastP1.x, y: lastP1.y),
            finger2: CGPoint(x: lastP2.x, y: lastP2.y)
        ))

        logger.info().log("multi-touch down at (\(startP1.x),\(startP1.y)) + (\(startP2.x),\(startP2.y)), up at (\(lastP1.x),\(lastP1.y)) + (\(lastP2.x),\(lastP2.y)) over \(safeSteps) steps")
        try await HIDInteractor.performHIDEvent(.composite(events), in: session, logger: logger)
    }

    /// Minimum delay between consecutive HID Indigo events. Below ~5 ms
    /// the underlying private function inside SimulatorKit returns nil
    /// for the second message — see the explanation above
    /// `MultiTouchDispatcher.run`. Picked conservatively at 5 ms so
    /// total wall-clock impact stays below the recogniser threshold.
    static let minimumStepMs = 5
}