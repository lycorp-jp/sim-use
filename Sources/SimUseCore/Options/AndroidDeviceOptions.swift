// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

/// Shared `--device` flag for `sim-use android <verb>` subcommands.
/// Mirrors `DeviceOptions` (including the deprecated `--udid` alias and
/// the same mutual-exclusion fast-fail) but **does not** auto-pick a
/// booted iOS simulator when both flags are omitted: there is no
/// equivalent of "the one booted simulator" on Android, and falling
/// back into iOS-only `DeviceResolver` from an Android verb would
/// produce a confusing `noSimulatorBooted` error in the wrong backend.
///
/// Adopt with `@OptionGroup public var device: AndroidDeviceOptions` on
/// every Android verb, call `try device.resolve()` from
/// `resolveDeferredArguments()`, and read `device.resolved` thereafter.
public struct AndroidDeviceOptions: ParsableArguments {
    @Option(
        name: .customLong("device"),
        help: "Android adb serial (e.g. `emulator-5554` or a real-device serial)."
    )
    public var device: String?

    @Option(
        name: .customLong("udid"),
        help: ArgumentHelp(
            "Deprecated alias for --device. Still accepted; may be removed in a future release.",
            visibility: .default
        )
    )
    public var udid: String?

    /// Resolved adb serial. Populated by `resolve()`; the empty string
    /// until then. See `DeviceOptions.resolved` for the rationale.
    public var resolved: String = ""

    public init() {}

    public mutating func resolve() throws {
        guard let explicit = try DeviceOptions.selectExplicit(device: device, udid: udid) else {
            // CLIError (not ValidationError) so the diagnostic survives
            // the `resolveDeferredArguments()` -> `run()` catch path —
            // see `DeviceOptions.selectExplicit` for the rationale.
            throw CLIError(errorDescription: "Pass --device <serial> (the adb serial of the target Android device or emulator).")
        }
        resolved = explicit
    }
}