// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `paste` verb. Owns the flag surface and
/// resolves the target platform, then delegates to the per-backend
/// command (`IOSSimPasteCommand` for iOS Simulator UDIDs,
/// `AndroidPasteCommand.performPaste` for adb serials).
///
/// `--via-menu` is iOS-only — Android's bridge already bypasses the
/// IME via ACTION_PASTE, so the menu detour is unnecessary there. The
/// Android execute path fails fast on `--via-menu` with an explanatory
/// error rather than approximating it.
struct Paste: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimPasteCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        abstract: "Paste text into the focused field via the simulator pasteboard (bypasses IME).",
        discussion: """
        Writes the text to the simulator pasteboard with `simctl pbcopy` and
        triggers Cmd+V. Characters reach the responder chain without going
        through the keyboard, so IME composition (e.g. Japanese kana) cannot
        munge ASCII input and arbitrary Unicode is safe.

        Two input delivery paths:

        1. DEFAULT (Cmd+V via HID) — fast, requires a **connected hardware
           keyboard** on the simulator (Simulator.app: I/O > Keyboard >
           Connect Hardware Keyboard = ON). Under soft-keyboard-only mode
           HID key events are dropped and the paste silently no-ops.

        2. --via-menu (touch-driven) — long-press on a target field and
           tap the iOS edit-menu "Paste" button. Works regardless of the
           hardware-keyboard toggle, because no key events are involved.
           Requires --target-id <AXUniqueId> or --target-x/--target-y so
           sim-use knows where to long-press. --replace additionally taps
           "Select All" first.

        Preconditions (default path):
        • Target field must already be focused (use `sim-use tap` first).
        • Hardware keyboard must be connected on the simulator.

        Preconditions (--via-menu path):
        • Target field must be able to receive a long-press (normal
          UITextField / UITextView). Focus is not required — the
          long-press itself focuses the field.

        Input Methods (mutually exclusive):
        1. Positional: sim-use paste "Hello 日本語" --udid UDID
        2. From stdin: echo -n "text" | sim-use paste --stdin --udid UDID
        3. From file:  sim-use paste --file input.txt --udid UDID

        Examples:
          # Default Cmd+V path
          sim-use tap --id chatTextField --udid UDID
          sim-use paste "ABC 123" --udid UDID                       # paste at caret
          sim-use paste "NEW" --replace --udid UDID                 # Cmd+A + paste

          # Soft-keyboard-friendly path
          sim-use paste "ABC 123" --via-menu --target-id chatTextField --udid UDID
          sim-use paste "NEW"    --replace --via-menu --target-id chatTextField --udid UDID
          sim-use paste "xy"     --via-menu --target-x 171 --target-y 513 --udid UDID
          printf '%s' "$CLIP" | sim-use paste --stdin --udid UDID

        iOS Pasteboard Privacy Prompt (iOS 16+):
        • First paste in an app session triggers either a modal "Allow Paste"
          dialog (iOS 16) or an inline Paste bubble above the keyboard
          (iOS 17+). Approving grants a ~60 s grace window for subsequent
          pastes in the same session. `sim-use paste` does not auto-dismiss the
          prompt — accept it once interactively, or pre-configure the
          per-app Settings > Paste from Other Apps toggle.

        Caveats:
        • Overwrites the simulator pasteboard.
        • Secure text entry fields (passwords) may disable programmatic paste;
          fall back to `sim-use type` for ASCII-only credentials.
        • Verify the result with `describe-ui --json | jq '.AXValue'` on most
          UIKit fields; custom controls may not reflect AXValue.
        """
    )

    @Argument(help: "The text to paste. Use quotes for text with spaces or special characters.")
    var text: String?

    @Flag(name: .customLong("stdin"), help: "Read text from standard input.")
    var useStdin: Bool = false

    @Option(name: .customLong("file"), help: "Read text from the specified file.")
    var inputFile: String?

    @Flag(name: .customLong("replace"), help: "Select all before pasting so the paste replaces the field's current content. Uses Cmd+A in the default path and 'Select All' in the menu path.")
    var replace: Bool = false

    @Flag(name: .customLong("via-menu"), help: "Use the iOS edit menu (long-press → tap Paste) instead of Cmd+V. Touch-only path, works with the soft keyboard showing or hardware keyboard disconnected. Requires --target-id or --target-x/y.")
    var viaMenu: Bool = false

    @Option(name: .customLong("target-id"), help: "For --via-menu: AXUniqueId of the field to long-press. Resolves via the live AX tree.")
    var targetID: String?

    @Option(name: .customLong("target-x"), help: "For --via-menu: X coordinate to long-press.")
    var targetX: Double?

    @Option(name: .customLong("target-y"), help: "For --via-menu: Y coordinate to long-press.")
    var targetY: Double?

    @Option(name: .customLong("long-press-duration"), help: "Seconds to hold on the field for the edit menu to appear (default: 0.8).")
    var longPressDuration: Double = 0.8

    @Option(name: .customLong("menu-timeout"), help: "Seconds to poll for the edit menu after long-press (default: 2.0).")
    var menuTimeout: Double = 2.0

    @OptionGroup var device: DeviceOptions

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    var daemonBypass: Bool { useStdin }

    func format(_ result: ExecutionResult) -> CommandOutput { .empty }

    func validate() throws {
        try IOSSimPasteCommand.validateOptions(
            text: text, useStdin: useStdin, inputFile: inputFile,
            viaMenu: viaMenu,
            targetID: targetID,
            targetX: targetX, targetY: targetY
        )
    }

    func clientPreflight() async {
        // iOS-only soft-keyboard probe — Android goes through
        // ACTION_PASTE and has no equivalent HID-keyboard trap.
        guard !PlatformRouter.looksLikeAndroid(device.resolved) else { return }
        var sub = IOSSimPasteCommand()
        sub.viaMenu = viaMenu
        sub.device = device
        sub.json = json
        await sub.clientPreflight()
    }

    func execute() async throws -> ExecutionResult {
        switch PlatformRouter.resolve(udid: device.resolved) {
        case .android:
            return try executeAndroid()
        case .iOSSim, .none:
            return try await executeIOSSim()
        }
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        var sub = IOSSimPasteCommand()
        sub.text = text
        sub.useStdin = useStdin
        sub.inputFile = inputFile
        sub.replace = replace
        sub.viaMenu = viaMenu
        sub.targetID = targetID
        sub.targetX = targetX
        sub.targetY = targetY
        sub.longPressDuration = longPressDuration
        sub.menuTimeout = menuTimeout
        sub.device = device
        sub.json = json
        return try await sub.execute()
    }

    private func executeAndroid() throws -> ExecutionResult {
        if viaMenu {
            throw CLIError(errorDescription: "--via-menu is iOS-only. On Android the bridge already bypasses the IME via ACTION_PASTE; pass the text directly (with --replace if you want to overwrite the field).")
        }
        let inputText = try IOSSimPasteCommand.resolveInputText(
            text: text, useStdin: useStdin, inputFile: inputFile,
            logger: nil
        )
        guard !inputText.isEmpty else {
            throw CLIError(errorDescription: "Input text is empty; nothing to paste.")
        }
        try AndroidPasteCommand.performPaste(
            udid: device.resolved,
            text: inputText,
            replace: replace
        )
        return ExecutionResult()
    }
}