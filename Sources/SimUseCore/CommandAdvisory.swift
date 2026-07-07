// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Per-command informational advisory carried in the success envelope under
/// `advisory`. Unlike `ProcessAdvisory` (`process`), this describes the
/// command result itself and is rendered client-side so daemon stderr never
/// swallows it.
public struct CommandAdvisory: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case fullScreenTapTarget = "full_screen_tap_target"
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
