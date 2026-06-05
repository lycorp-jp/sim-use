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

    @Argument(help: "Text to send.")
    public var text: String

    @Flag(name: .customLong("clear"), help: "Clear the existing text before typing (replace mode). Default appends at the caret — same shape as iOS HID's `sim-use type`.")
    public var clear: Bool = false

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {}}` envelope on success.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public init() {}
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        try Self.performType(udid: device.resolved, text: text, clear: clear)
        return ExecutionResult()
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        // `text.count` is grapheme-cluster count, not byte / scalar
        // count. Diagnostic names the unit explicitly so an agent
        // doesn't mis-read it as "characters" (Swift's "Character"
        // == grapheme cluster, but the colloquial meaning often
        // diverges — e.g. an emoji ZWJ sequence is 1 grapheme but
        // several scalars).
        CommandOutput(stderr: "type ok (graphemes=\(text.count), clear=\(clear))\n")
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