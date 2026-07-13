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

    @OptionGroup var targeting: TapTargetingOptions

    @Option(
        name: .customLong("duration"),
        help: ArgumentHelp(
            "How long to hold the touch in seconds. Defaults to 0.8 — clears the OS long-press threshold on both iOS (~0.5s) and Android (~0.5s) with margin. Increase if a stubborn recogniser needs more time; values above 10s are rejected."
        )
    )
    var duration: Double = 0.8

    @OptionGroup var timing: TapTimingOptions

    @OptionGroup var multiTouch: MultiTouchOptions

    @OptionGroup var device: DeviceOptions

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    typealias ExecutionResult = IOSSimTapCommand.ExecutionResult

    /// Same shared group validators as `Tap` / `IOSSimTapCommand` —
    /// same selector / coordinate / delay constraints apply, and the
    /// duration default (0.8) is in the [0, 10] range so the validator
    /// accepts it. ArgumentParser does not auto-validate nested option
    /// groups, so these explicit calls are load-bearing
    /// (`TapValidationParityTests` pins that every surface makes them).
    func validate() throws {
        try targeting.validate(alias: alias)
        try timing.validate()
        try TapTimingOptions.validateDuration(duration)
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
        let sub = makeIOSSubcommand()
        return try await sub.execute()
    }

    /// Construct the backend command and copy every parsed flag across.
    /// A missed field stays in ArgumentParser's wrapper-definition state
    /// and traps on first read (#42) — pinned by
    /// `ForwarderInitializationGuardTests`.
    func makeIOSSubcommand() -> IOSSimTapCommand {
        var sub = IOSSimTapCommand()
        sub.alias = alias
        sub.targeting = targeting
        sub.duration = duration
        sub.timing = timing
        sub.multiTouch = multiTouch
        sub.device = device
        sub.json = json
        return sub
    }

    /// Android path: same selector resolution as `tap`, then a
    /// `BridgeClient.swipe(start=end, durationMs)` via the duration-
    /// aware `AndroidTapCommand.performTap` entry point. One stroke
    /// with `start == end` is the Android-native long-press shape
    /// (`AccessibilityService.dispatchGesture` cannot hold a stroke
    /// across calls).
    private func executeAndroid() throws -> ExecutionResult {
        let frameFilter: SelectorFrameFilter? = {
            guard !targeting.frameSpecs.isEmpty else { return nil }
            return (try? SelectorFrameFilter(specs: targeting.frameSpecs))
        }()
        let selector = AndroidSelector(
            id: targeting.elementID,
            label: targeting.elementLabel,
            labelContains: targeting.labelContains,
            labelRegex: targeting.labelRegex,
            value: targeting.elementValue,
            valueContains: nil,
            valueRegex: nil,
            elementType: targeting.elementType,
            frame: frameFilter
        )
        let explicit = try TapCoordinateResolver.resolve(x: targeting.pointX, y: targeting.pointY, point: targeting.point)
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