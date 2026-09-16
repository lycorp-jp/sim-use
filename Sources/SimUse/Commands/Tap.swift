// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend
import iOSDeviceBackend

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
          sim-use tap -x 540 -y 200 --coordinate-space ui              # outline (visual-space) coordinates on a rotated device
          sim-use tap @11 --duration 0.05                              # hold briefly — needed for some UISwitch toggles
        """
    )

    @Argument(help: ArgumentHelp(
        "Shortcut alias for the element to tap. `@N` selects the N-th entry of the most recent `describe-ui` snapshot; `#N` selects the N-th cell of the dominant detected list; `#N@M` selects the N-th cell of the M-th list (1-indexed, M=1 = dominant); `#<id>` resolves an AXUniqueId via the live AX tree. Exclusive with --point/-x/-y and --id/--label/--value.",
        valueName: "alias"
    ))
    var alias: String?

    @OptionGroup var targeting: TapTargetingOptions

    @Option(
        name: .customLong("duration"),
        help: ArgumentHelp(
            "How long to hold the touch between down and up in seconds. Omitted by default — the tap is dispatched as a single combined HID event for minimum latency. Provide a small positive value (e.g. 0.05) when targeting controls whose gesture recognisers ignore zero-duration HID taps, most notably UISwitch (`CheckBox` in the outline)."
        )
    )
    var duration: Double?

    @OptionGroup var timing: TapTimingOptions

    @OptionGroup var multiTouch: MultiTouchOptions

    @OptionGroup var device: DeviceOptions

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve(allowPhysical: true)
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    typealias ExecutionResult = IOSSimTapCommand.ExecutionResult

    /// Same shared group validators as `IOSSimTapCommand.validate()` —
    /// ArgumentParser does not auto-validate nested option groups, so
    /// these explicit calls are load-bearing (`TapValidationParityTests`
    /// pins that every surface makes them).
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
        case .iOSDevice:
            return try await executeIOSDevice()
        case .iOSSim, .none:
            // .none here means the UDID didn't match either platform
            // shape; defer to iOS so the existing "not booted /
            // not found" message surfaces (preserving pre-refactor
            // error UX for typo UDIDs).
            return try await executeIOSSim()
        }
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        .line(result.summaryLine)
    }

    /// Forward to the iOS Simulator backend through its typed executor
    /// entry point — the parsed groups are handed over as values, so no
    /// backend command instance is hand-built and there is no per-field
    /// copy to forget (#42). Validation has already passed on this
    /// struct; `performTap` does not re-run it.
    private func executeIOSSim() async throws -> ExecutionResult {
        try await IOSSimTapCommand.performTap(
            alias: alias,
            targeting: targeting,
            timing: timing,
            duration: duration,
            multiTouch: multiTouch,
            device: device,
            json: json
        )
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

    /// Physical-iOS dispatch: routes the audit-channel-compatible subset
    /// through `IOSDeviceCommand.Tap.performTap` (shared with
    /// `sim-use ios-device tap`). Everything the channel cannot honour
    /// rejects up front via the decision table below — before any
    /// device I/O, so a wrong form fails in milliseconds, not after a
    /// multi-second tree read. `--pre-delay` / `--post-delay` are plain
    /// waits and are honoured like on the other platforms.
    private func executeIOSDevice() async throws -> ExecutionResult {
        if let rejection = Self.physicalFormRejection(
            alias: alias,
            targeting: targeting,
            duration: duration,
            timing: timing,
            multiTouch: multiTouch
        ) {
            throw rejection
        }
        let identifier: String?
        if let alias {
            guard case .id(let value) = OutlineAliasResolver.parse(alias) else {
                // The reject table already caught @N / #N / #N@M; what
                // remains is a token parse() cannot read at all.
                throw CLIError(errorDescription: "Positional target '\(alias)' is not a valid alias. On physical iOS devices use the literal `#<id>` shown in `sim-use ui`, or --label / --label-contains.")
            }
            identifier = value
        } else {
            identifier = targeting.elementID
        }
        if let preDelay = timing.preDelay, preDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(preDelay * 1_000_000_000))
        }
        let result = try await IOSDeviceCommand.Tap.performTap(
            udid: device.resolved,
            identifier: identifier,
            label: targeting.elementLabel,
            labelContains: targeting.labelContains,
            elementType: targeting.elementType
        )
        if let postDelay = timing.postDelay, postDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(postDelay * 1_000_000_000))
        }
        return ExecutionResult(
            action: result.action,
            role: result.role,
            label: result.label,
            identifier: result.identifier
        )
    }

    /// The decision table for tap forms on physical iOS: `#<id>`
    /// (positional or --id), --label / --label-contains, and
    /// --element-type route; every other form promises coordinate,
    /// cache, or resolver semantics the audit channel cannot provide.
    /// Static and pure so tests pin the whole table without a device.
    static func physicalFormRejection(
        alias: String?,
        targeting: TapTargetingOptions,
        duration: Double?,
        timing: TapTimingOptions,
        multiTouch: MultiTouchOptions
    ) -> TargetCapabilityError? {
        let interact = "Interact through accessibility actions instead: `sim-use ui` reads the outline, then `sim-use tap '#<id>'` or `--label` activates an element."
        if targeting.hasExplicitCoordinates {
            return .physicalIOS(
                verb: "tap -x/-y/--point",
                reason: "the accessibility audit channel exposes no element geometry or coordinate input.",
                alternative: interact
            )
        }
        if multiTouch.fingers > 1 || multiTouch.x2 != nil || multiTouch.y2 != nil {
            return .physicalIOS(
                verb: "tap --fingers/--x2/--y2",
                reason: "multi-touch is coordinate HID, which the accessibility audit channel does not carry.",
                alternative: interact
            )
        }
        if duration != nil {
            return .physicalIOS(
                verb: "tap --duration",
                reason: "the audit channel's only exposed action is Activate — there is no press-duration control.",
                alternative: "Drop --duration; if the control needs a long press, that gesture is not available on physical iOS devices yet."
            )
        }
        if targeting.elementValue != nil {
            return .physicalIOS(
                verb: "tap --value",
                reason: "the physical-device resolver matches accessibility identifiers and labels only; element values are not surfaced on this channel.",
                alternative: "Use `#<id>`, --label, or --label-contains (add --element-type to disambiguate)."
            )
        }
        if targeting.labelRegex != nil {
            return .physicalIOS(
                verb: "tap --label-regex",
                reason: "regex label matching is not implemented on the physical-device resolver.",
                alternative: "Use --label for an exact match or --label-contains for a substring."
            )
        }
        if !targeting.frameSpecs.isEmpty {
            return .physicalIOS(
                verb: "tap --frame",
                reason: "frame filters need element geometry, which the accessibility audit channel does not expose.",
                alternative: "Disambiguate with --element-type or a more specific label instead."
            )
        }
        if timing.waitTimeout > 0 {
            return .physicalIOS(
                verb: "tap --wait-timeout",
                reason: "element polling would re-read the multi-second device tree on every tick.",
                alternative: "Re-run the tap after the UI settles (a full tree read costs seconds on this channel)."
            )
        }
        switch alias.flatMap(OutlineAliasResolver.parse) {
        case .at:
            return .physicalIOS(
                verb: "tap @N",
                reason: "element handles expire between processes on this channel, so cached outline aliases cannot be replayed.",
                alternative: "Use the stable `#<id>` shown in `sim-use ui`, or --label."
            )
        case .list:
            return .physicalIOS(
                verb: "tap #N / #N@M",
                reason: "list-cell aliases come from the frame-based list detector, and the accessibility audit channel exposes no frames.",
                alternative: "Use the literal `#<id>` shown in `sim-use ui`, or --label / --label-contains."
            )
        case .id, .none:
            return nil
        }
    }
}