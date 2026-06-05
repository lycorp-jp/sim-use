// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android button` — global navigation keys.
///
/// Named `button` (not `press`) so the surface lines up with the
/// top-level `sim-use button <home|back|recents|…>` verb and the iOS
/// `sim-use ios button` peer. `press` stays registered as a hidden
/// alias for one release so 0.5.x scripts that already typed
/// `sim-use android press home` keep working.
public struct AndroidButtonCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "button",
        abstract: "Press one of the global navigation keys: home | back | recents.",
        aliases: ["press"]
    )

    public enum Button: String, ExpressibleByArgument, CaseIterable {
        case home, back, recents
        public var keyCode: Int {
            switch self {
            case .home: return 3
            case .back: return 4
            case .recents: return 187
            }
        }
    }

    @OptionGroup public var device: AndroidDeviceOptions

    @Argument(help: "home | back | recents")
    public var button: Button

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
        try Self.performPress(udid: device.resolved, keyCode: button.keyCode)
        return ExecutionResult()
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(
            stdout: "✓ \(button.rawValue.capitalized) button press completed successfully\n",
            stderr: "button \(button.rawValue) (keyCode=\(button.keyCode))\n"
        )
    }

    /// Reusable Android key-press entry point. Top-level cross-platform
    /// `Button` forwards here for Android UDIDs so both
    /// `sim-use android button` and `sim-use button` go through one
    /// body. Symmetric to `AndroidTapCommand.performTap`.
    ///
    /// Accepts a raw `keyCode` rather than a typed enum because the
    /// cross-platform `Button` verb supports additional actions
    /// (`lock` → KEYCODE_POWER) that `sim-use android button` doesn't
    /// expose at the CLI surface. The bridge tolerates any
    /// `KeyEvent.KEYCODE_*` value.
    public static func performPress(
        udid: String,
        keyCode: Int,
        controller: AndroidDeviceController = AndroidDeviceController()
    ) throws {
        let client = controller.bridge(serial: udid)
        try client.pressKey(keyCode)
    }
}