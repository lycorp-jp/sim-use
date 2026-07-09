// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `long-press` verb. Mirrors `Tap`'s entire
/// flag surface (selectors, frame filter, delays, wait/poll, UDID,
/// JSON) — the only difference is `--duration` defaults to 0.8s so
/// `sim-use long-press @5` is a one-liner that crosses the OS
/// long-press threshold on both platforms:
///   • iOS: HID `touchDownAt → sleep → touchUpAt` (split submission so
///     UILongPressGestureRecognizer observes a real hold).
///   • Android: `dispatchGesture` with a single `start == end` stroke
///     of the requested duration, dispatched through bridge `/swipe`.
///
/// Implementation is intentionally a thin shell: routing and per-
/// platform forwarding are copies of `Tap.executeIOSSim` /
/// `Tap.executeAndroid` with `duration` carried through. We do not
/// reconstruct a `Tap` instance because `Tap` is parsed by
/// ArgumentParser and has no callable empty initialiser outside that
/// pathway.
struct LongPress: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(
        commandName: "long-press",
        abstract: "Long-press an element by alias, selector, or coordinate (default hold 0.8s).",
        discussion: """
        Sugar over `sim-use tap --duration <seconds>` with `--duration`
        defaulting to 0.8s, the standard threshold that triggers
        long-press recognisers on both iOS and Android (above
        `UILongPressGestureRecognizer.minimumPressDuration` and
        `ViewConfiguration.getLongPressTimeout()`). Useful for
        chat-bubble action menus, launcher icon popups, and any UI
        where the action-press distinction matters.

        Targeting is identical to `tap` — same alias / selector /
        coordinate forms, same precedence, same describe-ui cache.
        See `sim-use tap --help` for the full workflow walkthrough;
        every targeting form documented there works here, just with
        a longer default hold.

        Examples:
          sim-use describe-ui                                         # populate the outline cache
          sim-use long-press @5                                       # 0.8s hold on outline entry 5
          sim-use long-press '#3'                                     # long-press the 3rd cell of the dominant list
          sim-use long-press --label "Photos"                         # exact AXLabel
          sim-use long-press --label-contains "メキシコ" --element-type Button   # substring + type filter
          sim-use long-press --label-regex '^[0-9]{1,2}:[0-9]{2}(\\s(AM|PM))?$'   # anchored regex (timestamp labels)
          sim-use long-press -x 540 -y 1268 --duration 1.2            # custom hold, raw coordinates
        """
    )

    @Argument(help: ArgumentHelp(
        "Shortcut alias for the element to long-press. `@N` selects the N-th entry of the most recent `describe-ui` snapshot; `#N` selects the N-th cell of the dominant detected list; `#N@M` selects the N-th cell of the M-th list (1-indexed, M=1 = dominant); `#<id>` resolves an AXUniqueId via the live AX tree. Exclusive with --point/-x/-y and --id/--label/--value.",
        valueName: "alias"
    ))
    var alias: String?

    @Option(name: [.customShort("x"), .customLong("x")], help: "The X coordinate of the long-press. Accepts -x or --x.")
    var pointX: Double?

    @Option(name: [.customShort("y"), .customLong("y")], help: "The Y coordinate of the long-press. Accepts -y or --y.")
    var pointY: Double?

    @Option(name: .customLong("point"), help: ArgumentHelp(
        "The point to long-press as a coordinate pair — same semantics as -x/-y; specify only one form.",
        valueName: "x,y"
    ))
    var point: CoordinatePair?

    @Option(name: [.customLong("id")], help: "Long-press the center of the element matching AXUniqueId/resource-id literally. For the N-th outline entry, use the positional `@N` alias instead — `--id 42` matches the identifier string '42', NOT outline alias @42. Ignored if explicit coordinates (-x/-y or --point) are provided.")
    var elementID: String?

    @Option(name: [.customLong("label")], help: "Long-press the center of the element matching AXLabel (accessibilityLabel). Ignored if explicit coordinates (-x/-y or --point) are provided.")
    var elementLabel: String?

    @Option(name: [.customLong("value")], help: "Long-press the center of the element matching AXValue (the current value of a control). Ignored if explicit coordinates (-x/-y or --point) are provided.")
    var elementValue: String?

    @Option(name: [.customLong("label-contains")], help: "Long-press the element whose AXLabel contains this case-sensitive substring. Useful when labels carry dynamic state (counters, timestamps). Mutually exclusive with --id/--label/--value/--label-regex.")
    var labelContains: String?

    @Option(name: [.customLong("label-regex")], help: "Long-press the element whose AXLabel matches this ICU regex. Anchor with ^/$ for exact match. Mutually exclusive with --id/--label/--value/--label-contains.")
    var labelRegex: String?

    @Option(name: [.customLong("element-type")], help: "Filter matches to elements of this accessibility type (e.g. Button, TextField). Narrows --id/--label/--value/--label-contains/--label-regex results when multiple elements match.")
    var elementType: String?

    @Option(
        name: .customLong("frame"),
        parsing: .singleValue,
        help: ArgumentHelp(
            "Geometric AND-filter on frame bounds. Repeatable. Each value is a comma-separated list of `key=value` pairs. Keys: minX, maxX, minY, maxY. Values are absolute pixels (e.g. 700) or 0..1 fractions of the screen with an `r` suffix (e.g. 0.6r). Combine with selectors to disambiguate when several elements share a label/pattern but live in different screen regions.",
            valueName: "key=value[,key=value]"
        )
    )
    var frameSpecs: [String] = []

    @Option(name: .customLong("pre-delay"), help: "Delay before the long-press in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after the long-press in seconds.")
    var postDelay: Double?

    @Option(
        name: .customLong("duration"),
        help: ArgumentHelp(
            "How long to hold the touch in seconds. Defaults to 0.8 — clears the OS long-press threshold on both iOS (~0.5s) and Android (~0.5s) with margin. Increase if a stubborn recogniser needs more time; values above 10s are rejected."
        )
    )
    var duration: Double = 0.8

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for the element before failing (0 = no waiting, default). Only applies to --id/--label/--value/--label-contains/--label-regex targeting.")
    var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active (default: 0.25).")
    var pollInterval: Double = 0.25

    @OptionGroup var multiTouch: MultiTouchOptions

    @OptionGroup var device: DeviceOptions

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    typealias ExecutionResult = IOSSimTapCommand.ExecutionResult

    func validate() throws {
        // Delegate to the shared tap rules — same selector / coordinate
        // / delay constraints apply. The duration default (0.8) is in
        // the [0, 10] range so the validator accepts it.
        try IOSSimTapCommand.validateOptions(
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

    func execute() async throws -> ExecutionResult {
        switch PlatformRouter.resolve(udid: device.resolved) {
        case .android:
            return try executeAndroid()
        case .iOSSim, .none:
            return try await executeIOSSim()
        }
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        .line("✓ Long-press at (\(result.x), \(result.y)) completed successfully")
    }

    /// iOS path: hand off to `IOSSimTapCommand` with `--duration`
    /// carried through. That sub-command already splits the HID event
    /// into down → sleep → up when duration > 0, which is exactly the
    /// long-press recipe.
    private func executeIOSSim() async throws -> ExecutionResult {
        var sub = IOSSimTapCommand()
        sub.alias = alias
        sub.pointX = pointX
        sub.pointY = pointY
        sub.point = point
        sub.elementID = elementID
        sub.elementLabel = elementLabel
        sub.elementValue = elementValue
        sub.labelContains = labelContains
        sub.labelRegex = labelRegex
        sub.elementType = elementType
        sub.frameSpecs = frameSpecs
        sub.preDelay = preDelay
        sub.postDelay = postDelay
        sub.duration = duration
        sub.waitTimeout = waitTimeout
        sub.pollInterval = pollInterval
        sub.multiTouch = multiTouch
        sub.device = device
        sub.json = json
        return try await sub.execute()
    }

    /// Android path: same selector resolution as `tap`, then a
    /// `BridgeClient.swipe(start=end, durationMs)` via the duration-
    /// aware `AndroidTapCommand.performTap` entry point. One stroke
    /// with `start == end` is the Android-native long-press shape
    /// (`AccessibilityService.dispatchGesture` cannot hold a stroke
    /// across calls).
    private func executeAndroid() throws -> ExecutionResult {
        let frameFilter: SelectorFrameFilter? = {
            guard !frameSpecs.isEmpty else { return nil }
            return (try? SelectorFrameFilter(specs: frameSpecs))
        }()
        let selector = AndroidSelector(
            id: elementID,
            label: elementLabel,
            labelContains: labelContains,
            labelRegex: labelRegex,
            value: elementValue,
            valueContains: nil,
            valueRegex: nil,
            elementType: elementType,
            frame: frameFilter
        )
        let explicit = try TapCoordinateResolver.resolve(x: pointX, y: pointY, point: point)
        let result = try AndroidTapCommand.performTap(
            udid: device.resolved,
            alias: alias,
            x: explicit.map { Int($0.x.rounded()) },
            y: explicit.map { Int($0.y.rounded()) },
            selector: selector,
            duration: duration,
            multiTouch: multiTouch
        )
        return ExecutionResult(x: Double(result.x), y: Double(result.y))
    }
}