// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Per-command informational advisory carried in the success envelope under
/// `advisory`. Unlike `ProcessAdvisory` (`process`), this describes the
/// command result itself and is rendered client-side so daemon stderr never
/// swallows it.
public struct CommandAdvisory: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case fullScreenTapTarget = "full_screen_tap_target"
        case orientationCalibrationFallback = "orientation_calibration_fallback"
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    /// Collapse several advisories into the single `advisory` slot the
    /// success envelope carries. Multi-step surfaces (batch) join their
    /// per-step messages line by line under the first advisory's kind;
    /// the renderer prefixes each line so the text output stays scannable.
    public static func merged(_ advisories: [CommandAdvisory]) -> CommandAdvisory? {
        guard let first = advisories.first else { return nil }
        guard advisories.count > 1 else { return first }
        return CommandAdvisory(
            kind: first.kind,
            message: advisories.map(\.message).joined(separator: "\n")
        )
    }
}

/// Adopted by `ExecutionResult` types that can carry a per-command
/// advisory. Both envelope layers hoist `commandAdvisory` to the
/// top-level `advisory` key: `executeAsDaemonResponse` on the daemon
/// side and `resolveExecutionResult` on the in-process side.
///
/// Contract: the advisory must NOT appear in the conformer's own
/// encoded output — the envelope carries it, so a synthesized Codable
/// that includes the stored property would silently duplicate it
/// inside `data`. Exclude it with a `CodingKeys` enum that omits the
/// property (give the property a default value so decode synthesis
/// keeps working), and register the conformer in
/// `CommandAdvisoryContractTests`, which pins exactly this.
public protocol CommandAdvisoryProviding {
    var commandAdvisory: CommandAdvisory? { get }
}

public enum CommandAdvisoryRenderer {
    public static func banner(for advisory: CommandAdvisory) -> String {
        advisory.message
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { "[i] \($0)" }
            .joined(separator: "\n")
    }
}
