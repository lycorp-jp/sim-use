// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `tap` verb. Owns the verb-specific flag
/// surface, resolves the target platform via `PlatformRouter`, then
/// delegates the actual work to the per-backend command struct
/// (`IOSSimTapCommand` for iOS UDIDs, `AndroidTapCommand.performTap`
/// for Android serials). Shared flag groups (`DeviceOptions`,
/// `JSONOutputOptions`) live in `SimUseCore/Options/` so the
/// declaration is identical to the one consumed by `sim-use ios tap`.
struct Tap: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tap on a specific point on the screen, or locate an element by accessibility and tap its center.",
        discussion: """
        Workflow: run `sim-use describe-ui` first to capture an
        outline of the current screen — every visible element gets an
        `@N` alias and (when applicable) a `#N` / `#N@M` list-cell
        alias. Then pass that alias positionally to `tap`. The
        snapshot is cached at `~/.sim-use/<udid>/last-outline.json`;
        re-run `describe-ui` whenever the UI changes (after a
        navigation, scroll, modal open / close).

        Targeting forms, in rough order of preference:
          1. Positional alias (`@N`, `#N`, `#N@M`) — fastest, no live
             AX round-trip. Reads the cached outline from the last
             `describe-ui`.
          2. `#<id>` positional alias — resolves the literal
             AXUniqueId / Android resource-id short-name against a
             fresh AX tree. Use when the UI may have shifted since
             the last `describe-ui`.
          3. `--id` / `--label` / `--value` selectors — same fresh-AX
             path; pick by accessibility identifier, label, or value.
             Combine with `--element-type` and `--frame` to
             disambiguate when multiple elements match.
          4. `--label-contains` / `--label-regex` — substring / ICU
             regex over AXLabel. Use when labels carry dynamic state
             (counters, timestamps).
          5. Raw coordinates (`--point x,y` or `-x` / `-y`) — last
             resort, no a11y resolution. Fragile to layout changes.

        On no-match or multi-match, `--json` errors include a `hint`
        field listing candidate labels so an agent can re-target
        without re-running `describe-ui`.

        Works on both iOS Simulators and connected Android devices;
        the UDID shape (UUID vs adb serial) decides the backend.

        Examples:
          sim-use describe-ui                                          # populate the outline cache first
          sim-use tap @5                                               # 5th outline entry (cache-backed)
          sim-use tap '#3'                                             # 3rd cell of the dominant list (quote # to escape shell)
          sim-use tap '#2@2'                                           # 2nd cell of the 2nd detected list
          sim-use tap '#settingsButton'                                # AXUniqueId via live AX tree
          sim-use tap --label "Photos"                                 # exact AXLabel
          sim-use tap --label-contains "Reply" --element-type Button   # substring + type filter
          sim-use tap --label-regex '^Reply [0-9]+$'                   # anchored ICU regex over AXLabel
          sim-use tap -x 540 -y 1268                                   # raw coordinates (last resort)
          sim-use tap --point 540,1268                                 # same, coordinate-pair form
          sim-use tap @11 --duration 0.05                              # hold briefly — needed for some UISwitch toggles
        """
    )

    @Argument(help: ArgumentHelp(
        "Shortcut alias for the element to tap. `@N` selects the N-th entry of the most recent `describe-ui` snapshot; `#N` selects the N-th cell of the dominant detected list; `#N@M` selects the N-th cell of the M-th list (1-indexed, M=1 = dominant); `#<id>` resolves an AXUniqueId via the live AX tree. Exclusive with --point/-x/-y and --id/--label/--value.",
        valueName: "alias"
    ))
    var alias: String?

    @Option(name: [.customShort("x"), .customLong("x")], help: "The X coordinate of the point to tap. Accepts -x or --x.")
    var pointX: Double?

    @Option(name: [.customShort("y"), .customLong("y")], help: "The Y coordinate of the point to tap. Accepts -y or --y.")
    var pointY: Double?

    @Option(name: .customLong("point"), help: ArgumentHelp(
        "The point to tap as a coordinate pair — same semantics as -x/-y; specify only one form.",
        valueName: "x,y"
    ))
    var point: CoordinatePair?

    @Option(name: [.customLong("id")], help: "Tap the center of the element matching AXUniqueId/resource-id literally. For the N-th outline entry, use the positional `@N` alias instead — `--id 42` matches the identifier string '42', NOT outline alias @42. Ignored if explicit coordinates (-x/-y or --point) are provided.")
    var elementID: String?

    @Option(name: [.customLong("label")], help: "Tap the center of the element matching AXLabel (accessibilityLabel). Ignored if explicit coordinates (-x/-y or --point) are provided.")
    var elementLabel: String?

    @Option(name: [.customLong("value")], help: "Tap the center of the element matching AXValue (the current value of a control). Ignored if explicit coordinates (-x/-y or --point) are provided.")
    var elementValue: String?

    @Option(name: [.customLong("label-contains")], help: "Tap the element whose AXLabel contains this case-sensitive substring. Useful when labels carry dynamic state (counters, timestamps). Mutually exclusive with --id/--label/--value/--label-regex.")
    var labelContains: String?

    @Option(name: [.customLong("label-regex")], help: "Tap the element whose AXLabel matches this ICU regex. Anchor with ^/$ for exact match. Mutually exclusive with --id/--label/--value/--label-contains.")
    var labelRegex: String?

    @Option(name: [.customLong("element-type")], help: "Filter matches to elements of this accessibility type (e.g. Button, TextField, Switch). Narrows --id/--label/--value/--label-contains/--label-regex results when multiple elements match.")
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

    @Option(name: .customLong("pre-delay"), help: "Delay before tapping in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after tapping in seconds.")
    var postDelay: Double?

    @Option(
        name: .customLong("duration"),
        help: ArgumentHelp(
            "How long to hold the touch between down and up in seconds. Omitted by default — the tap is dispatched as a single combined HID event for minimum latency. Provide a small positive value (e.g. 0.05) when targeting controls whose gesture recognisers ignore zero-duration HID taps, most notably UISwitch (`CheckBox` in the outline)."
        )
    )
    var duration: Double?

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
            // .none here means the UDID didn't match either platform
            // shape; defer to iOS so the existing "not booted /
            // not found" message surfaces (preserving pre-refactor
            // error UX for typo UDIDs).
            return try await executeIOSSim()
        }
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        .line("✓ Tap at (\(result.x), \(result.y)) completed successfully")
    }

    /// Forward to the iOS Simulator backend. Validation has already
    /// passed on the top-level struct, so the sub-command's `validate()`
    /// is intentionally skipped — ArgumentParser only calls `validate()`
    /// on the root parsed command, and re-running it here would double
    /// up the work for no benefit.
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
        return sub
    }

    /// Forward to the Android backend. Symmetric to `executeIOSSim` —
    /// constructs the AndroidBackend selector from the resolved flags
    /// and routes through `AndroidTapCommand.performTap`, the same
    /// entry point used by the explicit `sim-use android tap` form.
    /// Coordinates are rounded to the nearest pixel rather than
    /// truncated toward zero — `Int(199.9)` is 199 (one pixel off
    /// the user's intent) whereas `Int(199.9.rounded())` is 200. The
    /// iOS path keeps fractional coords natively so only the Android
    /// branch needs the explicit round.
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