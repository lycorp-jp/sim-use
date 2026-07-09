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

    @Option(name: [.customShort("x"), .customLong("x")], help: "The X coordinate of the point to tap. Accepts -x or --x.")
    public var pointX: Double?

    @Option(name: [.customShort("y"), .customLong("y")], help: "The Y coordinate of the point to tap. Accepts -y or --y.")
    public var pointY: Double?

    @Option(name: .customLong("point"), help: ArgumentHelp(
        "The point to tap as a coordinate pair — same semantics as -x/-y; specify only one form.",
        valueName: "x,y"
    ))
    public var point: CoordinatePair?

    @Option(name: [.customLong("id")], help: "Tap the center of the element matching AXUniqueId/resource-id literally. For the N-th outline entry, use the positional `@N` alias instead — `--id 42` matches the identifier string '42', NOT outline alias @42. Ignored if explicit coordinates (-x/-y or --point) are provided.")
    public var elementID: String?

    @Option(name: [.customLong("label")], help: "Tap the center of the element matching AXLabel (accessibilityLabel). Ignored if explicit coordinates (-x/-y or --point) are provided.")
    public var elementLabel: String?

    @Option(name: [.customLong("value")], help: "Tap the center of the element matching AXValue (the current value of a control). Ignored if explicit coordinates (-x/-y or --point) are provided.")
    public var elementValue: String?

    @Option(name: [.customLong("label-contains")], help: "Tap the element whose AXLabel contains this case-sensitive substring. Useful when labels carry dynamic state (counters, timestamps). Mutually exclusive with --id/--label/--value/--label-regex.")
    public var labelContains: String?

    @Option(name: [.customLong("label-regex")], help: "Tap the element whose AXLabel matches this ICU regex. Anchor with ^/$ for exact match. Mutually exclusive with --id/--label/--value/--label-contains.")
    public var labelRegex: String?

    @Option(name: [.customLong("element-type")], help: "Filter matches to elements of this accessibility type (e.g. Button, TextField, Switch). Narrows --id/--label/--value/--label-contains/--label-regex results when multiple elements match.")
    public var elementType: String?

    @Option(
        name: .customLong("frame"),
        parsing: .singleValue,
        help: ArgumentHelp(
            "Geometric AND-filter on frame bounds. Repeatable. Each value is a comma-separated list of `key=value` pairs. Keys: minX, maxX, minY, maxY. Values are absolute pixels (e.g. 700) or 0..1 fractions of the screen with an `r` suffix (e.g. 0.6r). Combine with selectors to disambiguate when several elements share a label/pattern but live in different screen regions.",
            valueName: "key=value[,key=value]"
        )
    )
    public var frameSpecs: [String] = []

    @Option(name: .customLong("pre-delay"), help: "Delay before tapping in seconds.")
    public var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after tapping in seconds.")
    public var postDelay: Double?

    @Option(
        name: .customLong("duration"),
        help: ArgumentHelp(
            "How long to hold the touch between down and up in seconds. Omitted by default — the tap is dispatched as a single combined HID event for minimum latency. Provide a small positive value (e.g. 0.05) when targeting controls whose gesture recognisers ignore zero-duration HID taps, most notably UISwitch (`CheckBox` in the outline)."
        )
    )
    public var duration: Double?

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for the element before failing (0 = no waiting, default). Only applies to --id/--label/--value/--label-contains/--label-regex targeting.")
    public var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active (default: 0.25).")
    public var pollInterval: Double = 0.25

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
        let filter = (try? AccessibilityTargetResolver.FrameFilter(specs: frameSpecs)) ?? .init()
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

    public func validate() throws {
        try Self.validateOptions(
            alias: alias,
            pointX: pointX, pointY: pointY, point: point,
            elementID: elementID,
            elementLabel: elementLabel,
            elementValue: elementValue,
            labelContains: labelContains,
            labelRegex: labelRegex,
            preDelay: preDelay,
            postDelay: postDelay,
            duration: duration,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            frameSpecs: frameSpecs
        )
        try multiTouch.validate()
    }

    /// Shared validation factored out as a static so the top-level
    /// cross-platform forwarder (`Sources/SimUse/Commands/Tap.swift`)
    /// runs the same rules without re-implementing them.
    public static func validateOptions(
        alias: String?,
        pointX: Double?,
        pointY: Double?,
        point: CoordinatePair?,
        elementID: String?,
        elementLabel: String?,
        elementValue: String?,
        labelContains: String?,
        labelRegex: String?,
        preDelay: Double?,
        postDelay: Double?,
        duration: Double?,
        waitTimeout: Double,
        pollInterval: Double,
        frameSpecs: [String]
    ) throws {
        if let alias {
            guard OutlineAliasResolver.looksLikeAlias(alias) else {
                throw ValidationError("Positional alias '\(alias)' must be `@N`, `#N`, `#N@M`, or `#<identifier>`.")
            }
            var conflicts: [String] = []
            if pointX != nil { conflicts.append("-x") }
            if pointY != nil { conflicts.append("-y") }
            if point != nil { conflicts.append("--point") }
            if elementID != nil { conflicts.append("--id") }
            if elementLabel != nil { conflicts.append("--label") }
            if elementValue != nil { conflicts.append("--value") }
            if labelContains != nil { conflicts.append("--label-contains") }
            if labelRegex != nil { conflicts.append("--label-regex") }
            if !conflicts.isEmpty {
                throw ValidationError("Alias '\(alias)' cannot be combined with \(conflicts.joined(separator: ", ")).")
            }
        } else if pointX != nil || pointY != nil || point != nil {
            _ = try TapCoordinateResolver.resolve(x: pointX, y: pointY, point: point)
        } else {
            let selectors: [(String, String?)] = [
                ("--id", elementID),
                ("--label", elementLabel),
                ("--value", elementValue),
                ("--label-contains", labelContains),
                ("--label-regex", labelRegex),
            ]
            let provided = selectors.filter { $0.1 != nil }
            if provided.isEmpty {
                throw ValidationError("Either provide an `@N` / `#N` / `#N@M` alias, coordinates (--point x,y or both -x/-y), or use --id/--label/--value/--label-contains/--label-regex to tap an element.")
            }
            if provided.count > 1 {
                let names = provided.map(\.0).joined(separator: ", ")
                throw ValidationError("Use only one of --id, --label, --value, --label-contains, --label-regex (got: \(names)).")
            }
            for (name, raw) in provided {
                if let raw, raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ValidationError("\(name) must not be empty.")
                }
            }
            if let labelRegex {
                do {
                    _ = try NSRegularExpression(pattern: labelRegex, options: [])
                } catch {
                    throw ValidationError("--label-regex '\(labelRegex)' is not a valid regular expression: \(error.localizedDescription)")
                }
            }
        }

        if let preDelay = preDelay {
            guard preDelay >= 0 && preDelay <= 10.0 else {
                throw ValidationError("Pre-delay must be between 0 and 10 seconds.")
            }
        }

        if let postDelay = postDelay {
            guard postDelay >= 0 && postDelay <= 10.0 else {
                throw ValidationError("Post-delay must be between 0 and 10 seconds.")
            }
        }

        if let duration {
            guard duration >= 0 && duration <= 10.0 else {
                throw ValidationError("--duration must be between 0 and 10 seconds.")
            }
        }

        guard waitTimeout >= 0 else {
            throw ValidationError("--wait-timeout must be non-negative.")
        }

        if waitTimeout > 0 {
            guard pollInterval > 0 else {
                throw ValidationError("--poll-interval must be greater than 0 when --wait-timeout is active.")
            }
        }

        if !frameSpecs.isEmpty {
            do {
                _ = try AccessibilityTargetResolver.FrameFilter(specs: frameSpecs)
            } catch let error as AccessibilityTargetResolver.FrameFilter.ParseError {
                throw ValidationError(error.message)
            }

            if pointX != nil || pointY != nil || point != nil {
                throw ValidationError("--frame cannot be combined with explicit -x/-y/--point coordinates (those bypass the AX tree).")
            }
            if let alias, case .some(let parsed) = OutlineAliasResolver.parse(alias) {
                switch parsed {
                case .at, .list:
                    throw ValidationError("--frame cannot be combined with the @N / #N / #N@M alias forms (they resolve to cached coordinates without consulting the AX tree). Use --label / --label-contains / --label-regex / --id / #<id> with --frame instead.")
                case .id:
                    break
                }
            }
        }
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
                        waitTimeout: waitTimeout,
                        pollInterval: pollInterval,
                        elementType: elementType,
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
        } else if let explicit = try TapCoordinateResolver.resolve(x: pointX, y: pointY, point: point) {
            resolvedPoint = (x: explicit.x, y: explicit.y)
            resolvedDescription = "(\(explicit.x), \(explicit.y))"
            resolvedAdvisory = nil
            calibration = nil
        } else {
            let query: AccessibilityQuery
            if let elementID {
                query = .id(elementID)
            } else if let elementLabel {
                query = .label(elementLabel)
            } else if let elementValue {
                query = .value(elementValue)
            } else if let labelContains {
                query = .labelContains(labelContains)
            } else if let labelRegex {
                query = .labelRegex(pattern: labelRegex)
            } else {
                throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.")
            }

            do {
                let hidTarget = try await AccessibilityPoller.resolveWithPollingHIDTarget(
                    query: query,
                    simulatorUDID: device.resolved,
                    waitTimeout: waitTimeout,
                    pollInterval: pollInterval,
                    elementType: elementType,
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

        if let preDelay = preDelay, preDelay > 0 {
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

        if let postDelay = postDelay, postDelay > 0 {
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
