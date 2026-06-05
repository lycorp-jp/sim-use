// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android paste` — set the device clipboard via the bridge
/// and dispatch ACTION_PASTE on the focused field. The bridge bypasses
/// the IME, so arbitrary Unicode lands intact without keyboard
/// composition.
///
/// `--replace` translates to a full-range SET_SELECTION on the focused
/// field before the paste action. There is no `--via-menu` peer on
/// Android — the bridge's ACTION_PASTE is itself the IME bypass.
public struct AndroidPasteCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "paste",
        abstract: "Paste text into the focused field via the device clipboard (bypasses IME)."
    )

    @OptionGroup public var device: AndroidDeviceOptions

    @Argument(help: "Text to paste.")
    public var text: String

    @Flag(name: .customLong("replace"), help: "Select all before pasting so the paste replaces the field's current content.")
    public var replace: Bool = false

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {}}` envelope on success.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public init() {}
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func validate() throws {
        if text.isEmpty {
            throw ValidationError("Input text is empty; nothing to paste.")
        }
    }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        try Self.performPaste(udid: device.resolved, text: text, replace: replace)
        return ExecutionResult()
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("✓ Paste (\(text.utf8.count) bytes) completed successfully")
    }

    /// Reusable Android paste entry point. Top-level cross-platform
    /// `Paste` forwards here for Android UDIDs so both
    /// `sim-use android paste` and `sim-use paste` go through one body.
    /// Symmetric to `AndroidTapCommand.performTap`.
    ///
    /// Translates the bridge's terse paste error codes
    /// (`clipboard_write_failed`, `paste_unsupported`) into the
    /// actionable messages produced by `friendlier`.
    public static func performPaste(
        udid: String,
        text: String,
        replace: Bool,
        controller: AndroidDeviceController = AndroidDeviceController()
    ) throws {
        let client = controller.bridge(serial: udid)
        do {
            try client.paste(text, replace: replace)
        } catch {
            throw friendlier(error)
        }
    }

    /// Translate the bridge's terse paste error envelopes into
    /// actionable agent guidance. Two bridge codes are common enough
    /// to call out by hand:
    ///
    ///   * `clipboard_write_failed` — Android 10+ blocks background
    ///     processes from writing the primary clip outside short
    ///     foreground-focus windows. The bridge is an
    ///     AccessibilityService, so it falls into that bucket.
    ///   * `paste_unsupported` — the focused field rejected
    ///     ACTION_PASTE (custom IME-backed editor or a WebView input
    ///     that doesn't honour the standard accessibility paste).
    ///
    /// Both are fully recoverable by switching to `sim-use type`,
    /// which the bridge types one character at a time without
    /// touching the clipboard or relying on ACTION_PASTE. Mirror of
    /// `AndroidScreenshotCommand.friendlier`.
    public static func friendlier(_ error: Error) -> Error {
        guard case BridgeError.applicationError(_, let code, _) = error else {
            return error
        }
        switch code {
        case "clipboard_write_failed":
            return BridgeError.applicationError(
                status: "error",
                code: "clipboard_write_failed",
                message: "Android refused the clipboard write (`ClipboardManager.setPrimaryClip` denied). Android 10+ blocks background processes from writing the primary clip outside short windows of foreground focus, and the bridge runs as an AccessibilityService — so `sim-use paste` is the wrong tool here. For plain text use `sim-use type \"...\"` instead; the bridge types characters directly without touching the clipboard."
            )
        case "paste_unsupported":
            return BridgeError.applicationError(
                status: "error",
                code: "paste_unsupported",
                message: "The focused field rejected ACTION_PASTE — most often a custom IME-backed editor or a WebView input that doesn't honour the standard accessibility paste action. Fall back to `sim-use type \"...\"` (or `sim-use type --file <path>` for large input); the bridge types characters one at a time and does not need the field to accept a paste action."
            )
        default:
            return error
        }
    }
}