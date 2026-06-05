// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import SimUseCore

/// Physical hardware button. Each case explicitly declares its iOS HID
/// button (via `iosHidButton`) and Android keycode (via `androidKeyCode`);
/// `nil` means the platform doesn't model the action. Cross-platform
/// dispatch in the top-level `Button` forwarder reads these mappings
/// and produces a clear "not supported on <platform>" error when the
/// user picks a button their target device doesn't have.
///
///                     | iOS HID         | Android keycode / global action
///   ----------------- | --------------- | -------------------------------
///   `home`            | HomeButton (2)  | KEYCODE_HOME (3)
///   `lock`            | Lock (3)        | KEYCODE_POWER (26) → GLOBAL_ACTION_LOCK_SCREEN
///   `back`            | —               | KEYCODE_BACK (4)
///   `recents`         | —               | KEYCODE_APP_SWITCH (187)
///   `apple-pay`       | ApplePay (1)    | —
///   `side-button`     | SideButton (4)  | —
///   `siri`            | Siri (5)        | —
public enum ButtonType: String, CaseIterable, ExpressibleByArgument {
    case home
    case lock
    case back
    case recents
    case applePay = "apple-pay"
    case sideButton = "side-button"
    case siri

    public var iosHidButton: FBSimulatorHIDButton? {
        switch self {
        case .home:       return FBSimulatorHIDButton(rawValue: 2)
        case .lock:       return FBSimulatorHIDButton(rawValue: 3)
        case .applePay:   return FBSimulatorHIDButton(rawValue: 1)
        case .sideButton: return FBSimulatorHIDButton(rawValue: 4)
        case .siri:       return FBSimulatorHIDButton(rawValue: 5)
        case .back, .recents: return nil
        }
    }

    public var androidKeyCode: Int? {
        switch self {
        case .home:    return 3
        case .back:    return 4
        case .lock:    return 26
        case .recents: return 187
        case .applePay, .sideButton, .siri: return nil
        }
    }

    public var description: String {
        switch self {
        case .applePay:   return "Apple Pay button"
        case .home:       return "Home button"
        case .lock:       return "Lock/Power button"
        case .sideButton: return "Side button"
        case .siri:       return "Siri button"
        case .back:       return "Back button"
        case .recents:    return "Recents button"
        }
    }

    public static var supportedOnIOSList: String {
        Self.allCases.filter { $0.iosHidButton != nil }.map(\.rawValue).joined(separator: ", ")
    }

    public static var supportedOnAndroidList: String {
        Self.allCases.filter { $0.androidKeyCode != nil }.map(\.rawValue).joined(separator: ", ")
    }
}

/// iOS Simulator backend for the `button` verb. Mirrors the flag
/// surface of top-level `Button` and is also reachable directly as
/// `sim-use ios button`. The top-level command resolves the target
/// platform via `PlatformRouter` and forwards iOS UDIDs through here.
public struct IOSSimButtonCommand: SimUseExecutableCommand {
    public struct ExecutionResult: Codable {
        public init() {}
    }

    public static let configuration = CommandConfiguration(
        commandName: "button",
        abstract: "Press a hardware button on the iOS simulator.",
        discussion: """
        Supported on iOS: home, lock, apple-pay, side-button, siri

        Examples:
          sim-use ios button home --udid SIMULATOR_UDID
          sim-use ios button lock --duration 2.0 --udid SIMULATOR_UDID
        """
    )

    @Argument(help: "The button to press.")
    public var buttonType: ButtonType

    @Option(name: .customLong("duration"), help: "Duration to hold the button in seconds.")
    public var duration: Double?

    @OptionGroup public var device: DeviceOptions

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("✓ \(buttonType.description) press completed successfully")
    }

    public func validate() throws {
        try Self.validateOptions(duration: duration)
    }

    /// Shared duration validation factored out as a static so the
    /// top-level cross-platform forwarder runs the same rules.
    public static func validateOptions(duration: Double?) throws {
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
        guard let hidButton = buttonType.iosHidButton else {
            throw CLIError(errorDescription:
                "`button \(buttonType.rawValue)` is not supported on iOS. Supported on iOS: \(ButtonType.supportedOnIOSList). For Android UDIDs (emulator-* / serial number) use one of: \(ButtonType.supportedOnAndroidList)."
            )
        }

        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        logger.info().log("Pressing \(buttonType.description)")
        if let duration {
            logger.info().log("Duration: \(duration) seconds")
        }

        let buttonEvent: FBSimulatorHIDEvent
        if let duration {
            let down = FBSimulatorHIDEvent.buttonDown(hidButton)
            let delayEvent = FBSimulatorHIDEvent.delay(duration)
            let up = FBSimulatorHIDEvent.buttonUp(hidButton)
            buttonEvent = FBSimulatorHIDEvent(events: [down, delayEvent, up])
        } else {
            buttonEvent = FBSimulatorHIDEvent.shortButtonPress(hidButton)
        }

        try await HIDInteractor.performHIDEvent(buttonEvent, for: device.resolved, logger: logger)
        logger.info().log("\(buttonType.description) press completed successfully")
        return ExecutionResult()
    }
}