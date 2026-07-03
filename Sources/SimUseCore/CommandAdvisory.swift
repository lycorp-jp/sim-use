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
}

public protocol CommandAdvisoryProviding {
    var commandAdvisory: CommandAdvisory? { get }
}

public enum CommandAdvisoryRenderer {
    public static func banner(for advisory: CommandAdvisory) -> String {
        "[i] \(advisory.message)"
    }
}
