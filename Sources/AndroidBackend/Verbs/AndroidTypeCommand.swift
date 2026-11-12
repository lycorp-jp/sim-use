// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android type` — set text on the focused EditText via
/// `/keyboard/input` (`ACTION_SET_TEXT`).
///
/// Defaults align with the cross-platform `sim-use type` verb,
/// which appends at caret (matching iOS HID's natural append
/// behaviour). Pass `--clear` to replace the field's existing
/// content before the new text lands.
public struct AndroidTypeCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Set text on the currently focused EditText (appends at caret by default)."
    )

    @OptionGroup public var device: AndroidDeviceOptions

    @Argument(help: "Text to send. Omit when --stdin is used so secrets (passwords, tokens) never appear in the process argv.")
    public var text: String?

    /// Matches the iOS backend's `--stdin`: the login workflow pipes
    /// credentials through stdin so they stay out of `ps` output and
    /// shell history. Android commands run in-process (no daemon),
    /// so the text is read directly here.
    @Flag(name: .customLong("stdin"), help: "Read text from standard input instead of the command line.")
    public var useStdin: Bool = false

    @Flag(name: .customLong("clear"), help: "Clear the existing text before typing (replace mode). Default appends at the caret — same shape as iOS HID's `sim-use type`.")
    public var clear: Bool = false

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {}}` envelope on success.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        /// Grapheme count of the typed text, for the diagnostic only.
        /// The text itself is never retained or echoed.
        public let graphemeCount: Int
        public init(graphemeCount: Int = 0) { self.graphemeCount = graphemeCount }
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    /// The daemon runs with stdin on /dev/null, so `--stdin` must be read
    /// here in the client and carried inline as the positional argument —
    /// same shape as the iOS backend. POSIX-level read instead of
    /// `readLine()`: intermittent nils on Swift Concurrency's cooperative
    /// pool would silently type nothing.
    public func daemonArguments(from arguments: [String]) throws -> [String] {
        guard useStdin else { return arguments }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let inputText = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .newlines) ?? ""
        return DaemonInlineInput.inliningText(inputText, into: arguments)
    }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func validate() throws {
        // Same one-source rule as the iOS backend: text argument or
        // --stdin, but not both. Zero sources is a usage error.
        let sourceCount = [text != nil, useStdin].filter { $0 }.count
        if sourceCount > 1 {
            throw ValidationError("Please specify only one input source: text argument or --stdin.")
        }
        if sourceCount == 0 {
            throw ValidationError("No input provided. Provide text as argument, or use --stdin.")
        }
    }

    public func execute() async throws -> ExecutionResult {
        let inputText: String
        if useStdin {
            // In-process path only (daemon dispatch already inlined the
            // text via daemonArguments and stripped --stdin). Read what
            // remains for robustness; normally empty.
            let data = FileHandle.standardInput.readDataToEndOfFile()
            inputText = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .newlines) ?? ""
        } else {
            inputText = text ?? ""
        }
        // Kept only for the diagnostic counter in format(); never logged.
        try Self.performType(udid: device.resolved, text: inputText, clear: clear)
        return ExecutionResult(graphemeCount: inputText.count)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        // `result.graphemeCount` is grapheme-cluster count, not byte /
        // scalar count. Diagnostic names the unit explicitly so an agent
        // doesn't mis-read it as "characters" (Swift's "Character"
        // == grapheme cluster, but the colloquial meaning often
        // diverges — e.g. an emoji ZWJ sequence is 1 grapheme but
        // several scalars). The text itself is never echoed: it may
        // have come from --stdin and contain a credential.
        CommandOutput(stderr: "type ok (graphemes=\(result.graphemeCount), clear=\(clear))\n")
    }

    /// Reusable Android type entry point. Top-level cross-platform
    /// `Type` forwards here for Android UDIDs so both
    /// `sim-use android type` and `sim-use type` go through one body.
    /// Symmetric to `AndroidTapCommand.performTap`.
    public static func performType(
        udid: String,
        text: String,
        clear: Bool,
        controller: AndroidDeviceController = AndroidDeviceController()
    ) throws {
        let client = controller.bridge(serial: udid)
        try client.inputText(text, clear: clear)
    }
}