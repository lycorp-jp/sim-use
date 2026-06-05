// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android keyboard-state` — query the bridge for the
/// current soft-keyboard visibility and active IME package. Mirrors
/// the iOS `keyboard-state` verb on the Android side; the cross-
/// platform top-level `keyboard-state` forwards here for Android
/// UDIDs.
public struct AndroidKeyboardStateCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "keyboard-state",
        abstract: "Report whether the soft keyboard is visible on the Android device."
    )

    @OptionGroup public var device: AndroidDeviceOptions

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {platform, visible, imePackage}}` envelope used by the cross-platform `keyboard-state --json`.")
    public var jsonOutput: Bool = false

    public init() {}

    /// Wire shape for the `data` field of the success envelope.
    /// Mirrors `IOSSimKeyboardStateCommand.ExecutionResult` so an
    /// agent script switching `--device` between an iOS and Android
    /// target sees the same schema regardless of platform.
    public struct ExecutionResult: Codable {
        public let platform: String
        public let visible: Bool
        public let imePackage: String?

        public init(visible: Bool, imePackage: String?) {
            self.platform = "android"
            self.visible = visible
            self.imePackage = imePackage
        }
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let state = try Self.performKeyboardState(udid: device.resolved)
        return ExecutionResult(visible: state.visible, imePackage: state.imePackage)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line(result.visible ? "soft" : "hidden")
    }

    /// Reusable Android keyboard-state probe. Top-level cross-platform
    /// `KeyboardState` forwards here for Android UDIDs so both
    /// `sim-use android keyboard-state` and `sim-use keyboard-state`
    /// share one body. Symmetric to `AndroidTapCommand.performTap`.
    public static func performKeyboardState(
        udid: String,
        controller: AndroidDeviceController = AndroidDeviceController()
    ) throws -> KeyboardStateResult {
        let client = controller.bridge(serial: udid)
        return try client.keyboardState()
    }
}