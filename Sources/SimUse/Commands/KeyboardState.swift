// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `keyboard-state` verb. Owns the flag
/// surface and resolves the target platform, then delegates to the
/// per-backend command (`IOSSimKeyboardStateCommand` for iOS
/// Simulator UDIDs, `AndroidKeyboardStateCommand.performKeyboardState`
/// for adb serials).
///
/// Uses the protocol-default `run()`: the soft-vs-hidden exit-code
/// semantics (both exit 0; non-zero reserved for genuine probe failure)
/// come from `execute()` returning a result rather than throwing, so no
/// custom `run()` is needed. See the note above `format(_:)`.
struct KeyboardState: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimKeyboardStateCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        commandName: "keyboard-state",
        abstract: "Report whether the on-screen software keyboard is currently visible.",
        discussion: """
        Inspects the frontmost app's accessibility tree for characteristic
        software-keyboard buttons. Useful when an automation script needs
        to pick between the default Cmd+V paste path (requires a connected
        hardware keyboard) and the `sim-use paste --via-menu` touch path
        (works regardless of the hardware-keyboard toggle).

        Text output:
          soft     # software keyboard visible
          hidden   # no software keyboard detected

        Exit code reflects probe success, not visibility — `soft` and
        `hidden` both exit 0; non-zero is reserved for genuine failure
        (unreachable device, AX tree fetch error). Branch on stdout:
          if [[ "$(sim-use keyboard-state --udid X)" == soft ]]; then ...

        JSON output (--json):
          {"visible": true, "chromeKeyCount": 6, "letterKeyCount": 26,
           "idChromeCount": 7, "globeSeen": true}

        Visibility is the OR of four independent signals on Button
        descendants of the AX tree:
          * idChromeCount  >= 2  — locale-proof AXIdentifier in
                                   {shift, delete, return, Search, more,
                                   emoji, dictation, space} (primary)
          * globeSeen            — label hits the small Next-Keyboard set
                                   {Next Keyboard, 次のキーボード,
                                    下一个键盘, 下一個鍵盤, 다음 키보드}
          * letterKeyCount >= 10 — single Latin letter buttons (QWERTY)
          * chromeKeyCount >= 3  — localized chrome label whitelist
                                   (legacy fallback)
        Any single signal is enough; all four counters are surfaced for
        debugging misfires.
        """
    )

    @OptionGroup var device: DeviceOptions

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    func execute() async throws -> ExecutionResult {
        switch PlatformRouter.resolve(udid: device.resolved) {
        case .android:
            let state = try AndroidKeyboardStateCommand.performKeyboardState(udid: device.resolved)
            return ExecutionResult(
                platform: "android",
                visible: state.visible,
                imePackage: state.imePackage
            )
        case .iOSSim, .none:
            let sub = makeIOSSubcommand()
            return try await sub.execute()
        }
    }

    /// Construct the backend command and copy every parsed flag across.
    /// A missed field stays in ArgumentParser's wrapper-definition state
    /// and traps on first read (#42) — pinned by
    /// `ForwarderInitializationGuardTests`.
    func makeIOSSubcommand() -> IOSSimKeyboardStateCommand {
        var sub = IOSSimKeyboardStateCommand()
        sub.device = device
        sub.json = json
        return sub
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        .line(result.visible ? "soft" : "hidden")
    }

    // No custom `run()`: the exit-code contract this command needs —
    // both `soft` and `hidden` exit 0, non-zero reserved for genuine
    // failure (device unreachable, AX fetch error) — falls out of the
    // protocol default. `execute()` returns a result for both keyboard
    // states rather than throwing, so the default `run()` renders it and
    // exits 0; only a thrown error exits non-zero. Callers branch on
    // stdout (`[[ $(sim-use keyboard-state --udid X) == soft ]]`) or on
    // `data.visible` in the JSON envelope.
    //
    // A pre-0.5.x override threw `ExitCode(1)` on `hidden`; when that was
    // dropped the override lingered and quietly opted the verb out of
    // daemon routing, the crash-advisory banner, and `Hint:` formatting.
    // Using the default `run()` restores all three and keeps the exit
    // codes identical.
}