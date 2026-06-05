// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `button` verb. Owns the flag surface and
/// resolves the target platform, then delegates to the per-backend
/// command (`IOSSimButtonCommand` for iOS Simulator UDIDs,
/// `AndroidButtonCommand.performPress` for adb serials).
///
/// The cross-platform `ButtonType` enum (re-exported from
/// iOSSimBackend) declares which subset of buttons exists on each
/// platform — both backends produce a clear "not supported on
/// <platform>" error when the user picks an action their device
/// doesn't have.
struct Button: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimButtonCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        abstract: "Press a hardware button on the simulator or Android device.",
        discussion: """
        iOS:     home, lock, apple-pay, side-button, siri
        Android: home, back, lock, recents

        Examples:
          sim-use button home --udid SIMULATOR_UDID
          sim-use button lock --duration 2.0 --udid SIMULATOR_UDID
          sim-use button back --udid emulator-5554
        """
    )

    @Argument(help: "The button to press.")
    var buttonType: ButtonType

    @Option(name: .customLong("duration"), help: "Duration to hold the button in seconds (iOS only; ignored for Android).")
    var duration: Double?

    @OptionGroup var device: DeviceOptions

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    func format(_ result: ExecutionResult) -> CommandOutput {
        .line("✓ \(buttonType.description) press completed successfully")
    }

    func validate() throws {
        try IOSSimButtonCommand.validateOptions(duration: duration)
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
        var sub = IOSSimButtonCommand()
        sub.buttonType = buttonType
        sub.duration = duration
        sub.device = device
        sub.json = json
        return try await sub.execute()
    }

    private func executeAndroid() throws -> ExecutionResult {
        guard let keyCode = buttonType.androidKeyCode else {
            throw CLIError(errorDescription:
                "`button \(buttonType.rawValue)` is not supported on Android. Supported on Android: \(ButtonType.supportedOnAndroidList). For iOS UDIDs use one of: \(ButtonType.supportedOnIOSList)."
            )
        }
        if duration != nil {
            // Android dispatch goes through `GLOBAL_ACTION_*` on the
            // a11y service, which is instantaneous — there's no
            // "hold for N seconds" semantic to honour.
            FileHandle.standardError.write(Data("warning: --duration is ignored on Android (global-action dispatch is instantaneous)\n".utf8))
        }
        try AndroidButtonCommand.performPress(udid: device.resolved, keyCode: keyCode)
        return ExecutionResult()
    }
}