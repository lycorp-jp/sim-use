// SPDX-License-Identifier: Apache-2.0
import Foundation

/// User-facing byte output produced by a command's `format(_:)` step.
///
/// The in-process CLI path and the future daemon client both emit these
/// bytes verbatim, so a single `format(_:)` implementation is the source
/// of truth for terminal output regardless of transport.
public struct CommandOutput: Equatable {
    public var stdout: String
    public var stderr: String

    public init(stdout: String = "", stderr: String = "") {
        self.stdout = stdout
        self.stderr = stderr
    }

    public func emit() {
        if !stderr.isEmpty {
            FileHandle.standardError.write(Data(stderr.utf8))
        }
        if !stdout.isEmpty {
            FileHandle.standardOutput.write(Data(stdout.utf8))
        }
    }

    public static let empty = CommandOutput()

    /// Single logical line: `text + "\n"` on stdout. Mirrors today's `print(text)` semantics.
    public static func line(_ text: String) -> CommandOutput {
        CommandOutput(stdout: text + "\n")
    }

    /// Multiple logical lines on stdout, each terminated with `\n`.
    public static func lines(_ texts: [String]) -> CommandOutput {
        guard !texts.isEmpty else { return .empty }
        return CommandOutput(stdout: texts.map { $0 + "\n" }.joined())
    }

    /// Raw stdout bytes, no trailing newline added. Mirrors `print(x, terminator: "")`.
    public static func raw(_ text: String) -> CommandOutput {
        CommandOutput(stdout: text)
    }
}