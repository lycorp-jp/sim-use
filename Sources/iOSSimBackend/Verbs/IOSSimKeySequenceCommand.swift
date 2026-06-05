// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import SimUseCore

/// iOS Simulator backend for the `key-sequence` verb. iOS-only — see
/// `IOSSimKeyCommand` for the rationale. Reach via
/// `sim-use ios key-sequence` only; path B keeps the top-level
/// surface honest.
public struct IOSSimKeySequenceCommand: SimUseExecutableCommand {
    public struct ExecutionResult: Codable {
        public init() {}
    }

    public static let configuration = CommandConfiguration(
        commandName: "key-sequence",
        abstract: "Press a sequence of keys by their keycodes on the iOS Simulator.",
        discussion: """
        Press multiple keys in sequence using their HID keycode values.
        Each key will be pressed and released before the next key is pressed.

        Examples:
          sim-use ios key-sequence 11,8,15,15,18 --udid UDID   # Type "hello" (h=11, e=8, l=15, l=15, o=18)
          sim-use ios key-sequence 40,40,40 --udid UDID        # Press Enter 3 times
          sim-use ios key-sequence 224,4,225 --udid UDID       # Ctrl+A (Ctrl=224, A=4, release Ctrl=225)
        """
    )

    @Option(name: .customLong("keycodes"), help: "Comma-separated list of HID keycodes to press in sequence.")
    public var keycodesString: String

    @Option(name: .customLong("delay"), help: "Delay between key presses in seconds (default: 0.1).")
    public var delay: Double?

    @OptionGroup public var device: DeviceOptions

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        if let arg = try DeviceOptions.selectExplicit(device: device.device, udid: device.udid),
           PlatformRouter.looksLikeAndroid(arg) {
            // CLIError so the message survives our run() catch — see
            // IOSSimKeyCommand for the rationale.
            throw CLIError(errorDescription: HIDKeyCommandHelp.androidUnsupportedMessage(verb: "ios key-sequence", udid: arg))
        }
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func format(_ result: ExecutionResult) -> CommandOutput { .empty }

    public func validate() throws {
        try Self.validateOptions(keycodesString: keycodesString, delay: delay)
    }

    public static func validateOptions(keycodesString: String, delay: Double?) throws {
        let parsedKeycodes = try parseCommaSeparatedIntsStrict(keycodesString, fieldName: "keycodes")

        guard !parsedKeycodes.isEmpty else {
            throw ValidationError("At least one keycode must be provided.")
        }
        for keycode in parsedKeycodes {
            guard keycode >= 0 && keycode <= 255 else {
                throw ValidationError("All keycodes must be between 0 and 255. Invalid keycode: \(keycode)")
            }
        }
        if let delay {
            guard delay >= 0 else {
                throw ValidationError("Delay must be non-negative.")
            }
            guard delay <= 5.0 else {
                throw ValidationError("Delay must not exceed 5 seconds.")
            }
        }
        guard parsedKeycodes.count <= 100 else {
            throw ValidationError("Key sequence must not exceed 100 keys.")
        }
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let parsedKeycodes = try parseCommaSeparatedIntsStrict(keycodesString, fieldName: "keycodes")
        let keyDelay = delay ?? 0.1

        logger.info().log("Pressing key sequence: \(parsedKeycodes)")
        logger.info().log("Delay between keys: \(keyDelay) seconds")

        var events: [FBSimulatorHIDEvent] = []
        for (index, keycode) in parsedKeycodes.enumerated() {
            events.append(FBSimulatorHIDEvent.shortKeyPress(UInt32(keycode)))
            if index < parsedKeycodes.count - 1 && keyDelay > 0 {
                events.append(FBSimulatorHIDEvent.delay(keyDelay))
            }
        }

        let sequenceEvent = FBSimulatorHIDEvent(events: events)
        try await HIDInteractor.performHIDEvent(
            sequenceEvent,
            for: device.resolved,
            logger: logger
        )

        logger.info().log("Key sequence completed successfully")
        return ExecutionResult()
    }
}