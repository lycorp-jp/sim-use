// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

/// Shared timing flag surface of the tap family (`tap`, `long-press`,
/// `ios tap`): delays around the action and the element-wait polling
/// knobs. Declared once so every surface parses identically and the
/// top-level forwarders transfer the whole parsed group (#42).
///
/// `--duration` is deliberately NOT part of this group — `tap` (nil
/// default, single combined HID event) and `long-press` (0.8s default)
/// disagree on both default and help text, so each command declares it
/// and runs `TapTimingOptions.validateDuration` alongside `validate()`.
public struct TapTimingOptions: ParsableArguments {
    @Option(name: .customLong("pre-delay"), help: "Delay before the action in seconds.")
    public var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after the action in seconds.")
    public var postDelay: Double?

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for the element before failing (0 = no waiting, default). Only applies to --id/--label/--value/--label-contains/--label-regex targeting.")
    public var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active (default: 0.25).")
    public var pollInterval: Double = 0.25

    public init() {}

    /// ArgumentParser (1.5.0) does not auto-validate nested option
    /// groups — each command must call this explicitly from its own
    /// `validate()`, the same convention `MultiTouchOptions.validate()`
    /// uses. `TapValidationParityTests` pins that all three surfaces do.
    public func validate() throws {
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

        guard waitTimeout >= 0 else {
            throw ValidationError("--wait-timeout must be non-negative.")
        }

        if waitTimeout > 0 {
            guard pollInterval > 0 else {
                throw ValidationError("--poll-interval must be greater than 0 when --wait-timeout is active.")
            }
        }
    }

    /// Range check for the per-command `--duration` flag (see the type
    /// doc for why the flag itself is not in this group).
    public static func validateDuration(_ duration: Double?) throws {
        if let duration {
            guard duration >= 0 && duration <= 10.0 else {
                throw ValidationError("--duration must be between 0 and 10 seconds.")
            }
        }
    }
}
