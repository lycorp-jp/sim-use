// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import SimUseCore

/// iOS Simulator backend for the `tap` verb. Mirrors the flag surface
/// of top-level `Tap` and is also reachable directly as
/// `sim-use ios tap`. The top-level command resolves the target
/// platform via `PlatformRouter` and forwards iOS UDIDs through here.
public struct IOSSimTapCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tap",
        abstract: "Tap on a specific point on the screen, or locate an element by accessibility and tap its center."
    )

    @Argument(help: ArgumentHelp(
        "Shortcut alias for the element to tap. `@N` selects the N-th entry of the most recent `describe-ui` snapshot; `#N` selects the N-th cell of the dominant detected list; `#N@M` selects the N-th cell of the M-th list (1-indexed, M=1 = dominant); `#<id>` resolves an AXUniqueId via the live AX tree. Exclusive with --point/-x/-y and --id/--label/--value.",
        valueName: "alias"
    ))
    public var alias: String?

    @OptionGroup public var targeting: TapTargetingOptions

    @Option(
        name: .customLong("duration"),
        help: ArgumentHelp(
            "How long to hold the touch between down and up in seconds. Omitted by default — the tap is dispatched as a single combined HID event for minimum latency. Provide a small positive value (e.g. 0.05) when targeting controls whose gesture recognisers ignore zero-duration HID taps, most notably UISwitch (`CheckBox` in the outline)."
        )
    )
    public var duration: Double?

    @OptionGroup public var timing: TapTimingOptions

    @OptionGroup public var multiTouch: MultiTouchOptions

    @OptionGroup public var device: DeviceOptions

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public var frameFilter: AccessibilityTargetResolver.FrameFilter? {
        // Validation guarantees parse success; force-try keeps execute()
        // free of throws-only-for-validate paths.
        let filter = (try? AccessibilityTargetResolver.FrameFilter(specs: targeting.frameSpecs)) ?? .init()
        return filter.isEmpty ? nil : filter
    }

    public struct ExecutionResult: Codable, CommandAdvisoryProviding {
        public let x: Double
        public let y: Double
        /// Excluded from the encoded `data` payload via `CodingKeys`
        /// (the default value keeps decode synthesis working) — the
        /// envelope hoists it to the top-level `advisory` key. See
        /// `CommandAdvisoryProviding` for the contract.
        public var commandAdvisory: CommandAdvisory? = nil

        public init(x: Double, y: Double, commandAdvisory: CommandAdvisory? = nil) {
            self.x = x
            self.y = y
            self.commandAdvisory = commandAdvisory
        }

        private enum CodingKeys: String, CodingKey {
            case x
            case y
        }
    }

    /// The rules themselves live on the shared groups
    /// (`TapTargetingOptions.validate(alias:)` /
    /// `TapTimingOptions.validate()`) so all three tap surfaces run the
    /// same table. ArgumentParser does not auto-validate nested option
    /// groups — the explicit calls here are load-bearing, and
    /// `TapValidationParityTests` pins that every surface makes them.
    public func validate() throws {
        try targeting.validate(alias: alias)
        try timing.validate()
        try TapTimingOptions.validateDuration(duration)
        try multiTouch.validate()
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let resolvedPoint: (x: Double, y: Double)
        let resolvedDescription: String
        let resolvedAdvisory: CommandAdvisory?
        // Non-nil for AX-derived targets: their coordinates are UI space
        // and must be transformed into framebuffer space before HID
        // dispatch (issue #34). Explicit -x/-y stays raw by contract.
        let calibration: OrientationCalibration?

        if let alias {
            switch OutlineAliasResolver.parse(alias) {
            case .at, .list:
                do {
                    let (resolved, entry, payload) = try OutlineAliasResolver.resolveWithPayload(alias, udid: device.resolved)
                    resolvedPoint = resolved.point
                    resolvedDescription = resolved.humanDescription
                    let snapshotCalibration = await OrientationCalibrator.calibrate(
                        udid: device.resolved,
                        snapshotEntry: entry,
                        payload: payload,
                        logger: logger
                    )
                    calibration = snapshotCalibration
                    resolvedAdvisory = CommandAdvisory.merged([
                        snapshotCalibration.advisory,
                        Self.staleSnapshotAdvisory(calibration: snapshotCalibration, payload: payload),
                    ].compactMap { $0 })
                } catch {
                    if !jsonOutput {
                        print("Warning: \(error.localizedDescription) No tap performed.", to: &standardError)
                    }
                    throw error
                }
            case .id(let uniqueId):
                // `#<id>` delegates to the live-AX `--id` path so it
                // benefits from the same wait-timeout / ambiguity
                // handling. No alias cache read — the selector is
                // self-contained and works across multiple snapshots.
                do {
                    let hidTarget = try await AccessibilityPoller.resolveWithPollingHIDTarget(
                        query: .id(uniqueId),
                        simulatorUDID: device.resolved,
                        waitTimeout: timing.waitTimeout,
                        pollInterval: timing.pollInterval,
                        elementType: targeting.elementType,
                        frameFilter: frameFilter,
                        logger: logger
                    )
                    resolvedPoint = hidTarget.ui
                    resolvedAdvisory = hidTarget.advisory
                    calibration = hidTarget.calibration
                    resolvedDescription = "#\(uniqueId) (AXUniqueId) at (\(resolvedPoint.x), \(resolvedPoint.y))"
                } catch let error as ElementResolutionError {
                    if !jsonOutput {
                        print("Warning: \(error.localizedDescription) No tap performed.", to: &standardError)
                    }
                    throw error
                }
            case nil:
                throw CLIError(errorDescription: "Internal error: alias '\(alias)' passed validation but could not be parsed.")
            }
        } else if let explicit = try TapCoordinateResolver.resolve(x: targeting.pointX, y: targeting.pointY, point: targeting.point) {
            resolvedPoint = (x: explicit.x, y: explicit.y)
            resolvedDescription = "(\(explicit.x), \(explicit.y))"
            resolvedAdvisory = nil
            calibration = nil
        } else {
            let query: AccessibilityQuery
            if let elementID = targeting.elementID {
                query = .id(elementID)
            } else if let elementLabel = targeting.elementLabel {
                query = .label(elementLabel)
            } else if let elementValue = targeting.elementValue {
                query = .value(elementValue)
            } else if let labelContains = targeting.labelContains {
                query = .labelContains(labelContains)
            } else if let labelRegex = targeting.labelRegex {
                query = .labelRegex(pattern: labelRegex)
            } else {
                throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.")
            }

            do {
                let hidTarget = try await AccessibilityPoller.resolveWithPollingHIDTarget(
                    query: query,
                    simulatorUDID: device.resolved,
                    waitTimeout: timing.waitTimeout,
                    pollInterval: timing.pollInterval,
                    elementType: targeting.elementType,
                    frameFilter: frameFilter,
                    logger: logger
                )
                resolvedPoint = hidTarget.ui
                resolvedAdvisory = hidTarget.advisory
                calibration = hidTarget.calibration
            } catch let error as ElementResolutionError {
                if !jsonOutput {
                    print("Warning: \(error.localizedDescription) No tap performed.", to: &standardError)
                }
                throw error
            }

            resolvedDescription = "center of matched element at (\(resolvedPoint.x), \(resolvedPoint.y))"
        }

        // UI space → framebuffer space for HID; identity (and -x/-y) pass
        // through untouched. Logging and ExecutionResult keep UI-space
        // coordinates so output matches the outline the user is reading.
        let dispatchPoint = calibration?.hidPoint(x: resolvedPoint.x, y: resolvedPoint.y) ?? resolvedPoint

        logger.info().log("Tapping at \(resolvedDescription)")
        if dispatchPoint != resolvedPoint, let calibration {
            logger.info().log("Orientation \(calibration.orientation.rawValue): dispatching HID at (\(dispatchPoint.x), \(dispatchPoint.y))")
        }

        if let preDelay = timing.preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
            try await Task.sleep(nanoseconds: UInt64(preDelay * 1_000_000_000))
        }

        if multiTouch.fingers == 2 {
            // Finger geometry is defined in UI space (offsets relative to
            // what the user sees); both fingers cross into framebuffer
            // space together.
            let finger2UI = multiTouch.fingerTwoPoint(forFinger1: resolvedPoint)
            let finger2 = calibration?.hidPoint(x: finger2UI.x, y: finger2UI.y) ?? finger2UI
            logger.info().log("Two-finger tap: finger1=(\(resolvedPoint.x),\(resolvedPoint.y)) finger2=(\(finger2UI.x),\(finger2UI.y)) duration=\(duration ?? 0)s")
            // The Down+Up shape with no Move events still registers as
            // a continuous gesture (the recogniser keys on finger
            // identifier continuity, not event count). When a duration
            // is supplied we hold via sleep between Down and Up so
            // UILongPressGestureRecognizer observes the hold; for the
            // instantaneous tap path we still send one Move so iOS
            // sees a complete (Down → Move → Up) stream.
            let session = try await HIDInteractor.makeSession(for: device.resolved, logger: logger)
            let hold = duration ?? 0
            // Empirical: sending Down → Move → Up with no gap between
            // events makes SimulatorKit's `IndigoHIDMessageForMouseNSEvent`
            // return nil for the second message — likely an internal
            // state-machine constraint. The MultiTouchDispatcher sleeps
            // twice per call (Down→Move, Move→Up), so a `--duration D`
            // hold needs stepMs = D*500 to land at a wall-clock of D
            // seconds. Without the halving the hold would be ~2×D.
            // For the instantaneous tap path (no duration), keep the
            // 30 ms breathing-room minimum on each gap.
            let minStepMs = 30
            let stepMs = hold > 0 ? max(minStepMs, Int((hold * 500).rounded())) : minStepMs
            try await MultiTouchDispatcher.run(
                session: session,
                start: (p1: dispatchPoint, p2: finger2),
                end: (p1: dispatchPoint, p2: finger2),
                steps: 1,
                stepMs: stepMs,
                logger: logger
            )
        } else if let duration, duration > 0 {
            // Split the tap into down → sleep → up so iOS gesture
            // recognisers (notably UISwitch in merged-a11y cells) observe
            // a real hold duration. A combined `.tapAt` event submits
            // down and up effectively simultaneously and is ignored by
            // some recognisers.
            logger.info().log("Touch down (hold \(duration)s)")
            try await HIDInteractor.performHIDEvent(
                FBSimulatorHIDEvent.touchDownAt(x: dispatchPoint.x, y: dispatchPoint.y),
                for: device.resolved,
                logger: logger
            )
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            logger.info().log("Touch up")
            try await HIDInteractor.performHIDEvent(
                FBSimulatorHIDEvent.touchUpAt(x: dispatchPoint.x, y: dispatchPoint.y),
                for: device.resolved,
                logger: logger
            )
        } else {
            try await HIDInteractor.performHIDEvent(
                FBSimulatorHIDEvent.tapAt(x: dispatchPoint.x, y: dispatchPoint.y),
                for: device.resolved,
                logger: logger
            )
        }

        if let postDelay = timing.postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            try await Task.sleep(nanoseconds: UInt64(postDelay * 1_000_000_000))
        }

        logger.info().log("Tap completed successfully")
        return ExecutionResult(x: resolvedPoint.x, y: resolvedPoint.y, commandAdvisory: resolvedAdvisory)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("✓ Tap at (\(result.x), \(result.y)) completed successfully")
    }

    /// The `@N` cache was written by a `describe-ui` run whose screen
    /// size no longer matches the calibrated orientation's UI size —
    /// either the device rotated since the snapshot or the foreground
    /// screen changed shape. The tap still proceeds best-effort (the
    /// transform is correct for coordinates that are still valid), but
    /// the caller should know why it might have missed.
    static func staleSnapshotAdvisory(
        calibration: OrientationCalibration,
        payload: OutlineCache.Payload
    ) -> CommandAdvisory? {
        guard let native = calibration.native else { return nil }
        let size = calibration.orientation.uiSize(native: native)
        guard abs(size.width - Double(payload.screen.width)) > 1
            || abs(size.height - Double(payload.screen.height)) > 1
        else { return nil }
        return CommandAdvisory(
            kind: .orientationCalibrationFallback,
            message: "Snapshot was captured at \(payload.screen.width)x\(payload.screen.height) but the current \(calibration.orientation.rawValue) screen is \(Int(size.width))x\(Int(size.height)) — the device rotated or the screen changed since describe-ui; cached @N coordinates may be stale. Re-run describe-ui."
        )
    }
}
