// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// iOS Simulator backend for `sim-use ios rotate`: turns the device so the
/// display that hosts the app shows the requested interface orientation.
/// Works on single-display simulators (Purple GSEvent) and on multi-display
/// ones such as iPhone Duo (orientation picker report). Work record:
/// docs/ai/010-display-routing/000-plan.md.
public struct IOSSimRotateCommand: SimUseExecutableCommand {
    public struct ExecutionResult: Codable, CommandAdvisoryProviding {
        public let rotate: PostureController.RotateOutcome
        public var commandAdvisory: CommandAdvisory? = nil

        private enum CodingKeys: String, CodingKey {
            case rotate
        }
    }

    public static let configuration = CommandConfiguration(
        commandName: "rotate",
        abstract: "Rotate the iOS Simulator to an interface orientation.",
        discussion: """
        Orientations are interface orientations — the same names the \
        `describe-ui` header uses: portrait, landscape-left, \
        landscape-right, portrait-upside-down. The command turns the \
        device so the display that hosts the app shows that orientation, \
        then reads the result back from CoreDevice.

        An app that does not support the orientation stays as it is; the \
        command then succeeds with an advisory that names the orientation \
        the interface kept. Refused during a Resize Mode session, which is \
        portrait-only.

        A rotation changes the screen geometry, so the cached describe-ui \
        snapshot is cleared; run `describe-ui` again before `tap @N`.

        Examples:
          sim-use ios rotate landscape-left --device UDID
          sim-use ios rotate portrait --json --device UDID
        """
    )

    @Argument(help: "portrait, landscape-left, landscape-right, or portrait-upside-down.")
    public var orientation: String

    @Option(name: .customLong("timeout"), help: "Seconds to wait for CoreDevice to confirm the rotation (default 5).")
    public var timeout: Double = 5

    @OptionGroup public var device: DeviceOptions

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        if let arg = try DeviceOptions.selectExplicit(device: device.device, udid: device.udid),
           PlatformRouter.looksLikeAndroid(arg) {
            throw CLIError(errorDescription: HIDKeyCommandHelp.androidUnsupportedMessage(verb: "ios rotate", udid: arg))
        }
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func validate() throws {
        guard DisplayOrientation(rawValue: orientation) != nil else {
            let names = DisplayOrientation.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("Orientation must be one of: \(names) (got '\(orientation)').")
        }
        guard timeout > 0, timeout <= 60 else {
            throw ValidationError("--timeout must be between 0 and 60 seconds.")
        }
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        let outcome = result.rotate
        guard let reached = outcome.orientation else {
            return .line("Sent device orientation \(outcome.deviceOrientation); the result could not be read back.")
        }
        let display = outcome.posture?.activeDisplay.map { " on display \($0.name)" } ?? ""
        if outcome.confirmed {
            return .line("Rotated to \(reached)\(display) (device \(outcome.deviceOrientation)).")
        }
        return .line("Not rotated: the interface\(display) stayed \(reached) (\(outcome.requested) not accepted).")
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await performGlobalSetup(logger: logger)
        guard let target = DisplayOrientation(rawValue: orientation) else {
            throw ValidationError("Unknown orientation '\(orientation)'.")
        }
        let (outcome, advisory) = try await PostureController.rotate(
            udid: device.resolved, target: target, timeout: timeout, logger: logger
        )
        return ExecutionResult(rotate: outcome, commandAdvisory: advisory)
    }
}
