// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import SimUseCore

/// iOS Simulator backend for the `key` verb. iOS-only — there's no
/// `sim-use key` at the top-level surface and no Android peer
/// because Android KeyEvents are a different abstraction (third-party
/// apps cannot inject USB HID Usage IDs into the system event stream
/// without the `INJECT_EVENTS` permission). Reach via
/// `sim-use ios key <code>` instead.
public struct IOSSimKeyCommand: SimUseExecutableCommand {
    public struct ExecutionResult: Codable {
        public init() {}
    }

    public static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Press a single key by keycode on the iOS Simulator.",
        discussion: """
        Press individual keys using their HID keycode values.

        Common keycodes:
          40 - Return/Enter
          42 - Backspace
          43 - Tab
          44 - Space
          58-67 - F1-F10
          224-231 - Modifier keys (Ctrl, Shift, Alt, etc.)

        Examples:
          sim-use ios key 40 --udid SIMULATOR_UDID                    # Press Enter
          sim-use ios key 44 --udid SIMULATOR_UDID                    # Press Space
          sim-use ios key 42 --duration 1.0 --udid SIMULATOR_UDID    # Hold Backspace for 1 second
        """
    )

    @Argument(help: "The HID keycode to press (0-255).")
    public var keycode: Int

    @Option(name: .customLong("duration"), help: "Duration to hold the key in seconds (optional).")
    public var duration: Double?

    @OptionGroup public var device: DeviceOptions

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        if let arg = try DeviceOptions.selectExplicit(device: device.device, udid: device.udid),
           PlatformRouter.looksLikeAndroid(arg) {
            // CLIError (not ArgumentParser.ValidationError) so the
            // message survives `SimUseExecutableCommand.run()`'s catch
            // block, which surfaces `error.localizedDescription`.
            // ValidationError doesn't supply a LocalizedError witness
            // and degrades to the opaque NSError bridge default.
            throw CLIError(errorDescription: HIDKeyCommandHelp.androidUnsupportedMessage(verb: "ios key", udid: arg))
        }
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func format(_ result: ExecutionResult) -> CommandOutput { .empty }

    public func validate() throws {
        try Self.validateOptions(keycode: keycode, duration: duration)
    }

    /// Shared option validation. Kept as a static so other call-sites
    /// can run the same rules without re-implementing them.
    public static func validateOptions(keycode: Int, duration: Double?) throws {
        guard keycode >= 0 && keycode <= 255 else {
            throw ValidationError("Keycode must be between 0 and 255.")
        }
        if let duration {
            guard duration > 0 else {
                throw ValidationError("Duration must be greater than 0.")
            }
            guard duration <= 10.0 else {
                throw ValidationError("Duration must not exceed 10 seconds.")
            }
        }
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        logger.info().log("Pressing key with keycode: \(keycode)")
        if let duration {
            logger.info().log("Duration: \(duration) seconds")
        }

        let keyEvent: FBSimulatorHIDEvent
        if let duration {
            let keyDownEvent = FBSimulatorHIDEvent.keyDown(UInt32(keycode))
            let delayEvent = FBSimulatorHIDEvent.delay(duration)
            let keyUpEvent = FBSimulatorHIDEvent.keyUp(UInt32(keycode))
            keyEvent = FBSimulatorHIDEvent(events: [keyDownEvent, delayEvent, keyUpEvent])
        } else {
            keyEvent = FBSimulatorHIDEvent.shortKeyPress(UInt32(keycode))
        }

        try await HIDInteractor.performHIDEvent(
            keyEvent,
            for: device.resolved,
            logger: logger
        )

        logger.info().log("Key press completed successfully")
        return ExecutionResult()
    }
}