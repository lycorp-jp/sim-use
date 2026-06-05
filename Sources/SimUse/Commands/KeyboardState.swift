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
/// Overrides `run()` so the JSON envelope shape (`{ok, data}` /
/// `{ok, error}`) and the soft-vs-hidden exit-code semantics stay
/// stable across the migration — both `soft` and `hidden` exit 0;
/// non-zero is reserved for genuine probe failure.
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
            var sub = IOSSimKeyboardStateCommand()
            sub.device = device
            sub.json = json
            return try await sub.execute()
        }
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        .line(result.visible ? "soft" : "hidden")
    }

    // `hidden` is a valid probe result, not a failure: until 0.5.x this
    // path threw `ExitCode(1)` on hidden so shell pipelines could branch
    // with `if sim-use keyboard-state --udid X; then ...`. That shape
    // conflated "keyboard is hidden" (an expected steady state on
    // Android, and on iOS whenever no field is focused) with genuine
    // failure (device unreachable, AX fetch error), making non-zero
    // unusable as a real error signal — every wrapper script had to
    // distinguish the two by parsing stderr. Both `soft` and `hidden`
    // now exit 0; callers branch on stdout (`[[ $(sim-use keyboard-state
    // --udid X) == soft ]]`) or on `data.visible` in the JSON envelope.
    //
    // The override still skips the protocol-default `run()` (which is
    // what wires `resolveDeferredArguments()` for every other command),
    // so we call the resolver explicitly. Without this the
    // `simulatorUDID` stays empty and every dispatch fails with
    // `"Simulator with UDID  not found in set."`.
    mutating func run() async throws {
        if jsonOutput {
            do {
                try resolveDeferredArguments()
                let result = try await execute()
                try JSONEnvelopeWriter.writeSuccess(result)
            } catch {
                JSONEnvelopeWriter.writeError(error)
                throw ExitCode(1)
            }
            return
        }

        try resolveDeferredArguments()
        let result = try await execute()
        format(result).emit()
    }
}