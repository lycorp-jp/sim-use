// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// iOS Simulator backend for `sim-use ios fold`: sets the hinge of a
/// foldable simulator (iPhone Duo) the way Device Hub's posture buttons do,
/// then confirms which display hosts the interface. iOS-only for now; the
/// arguments are platform-neutral so an Android foldable can share them.
/// Work record: docs/ai/010-display-routing/000-plan.md.
public struct IOSSimFoldCommand: SimUseExecutableCommand {
    public struct ExecutionResult: Codable {
        /// The requested posture (`closed`, `open`, `half`, or degrees);
        /// absent when only reporting.
        public let requested: String?
        public let hingeAngle: Double?
        /// The expected display became active (always true for an
        /// intermediate angle, which has no expectation).
        public let confirmed: Bool?
        /// The posture now (after the change, when one was made).
        public let posture: PostureReport

        init(fold: PostureController.FoldOutcome?, posture: PostureReport) {
            requested = fold?.requested
            hingeAngle = fold?.hingeAngle
            confirmed = fold?.confirmed
            self.posture = posture
        }
    }

    public static let configuration = CommandConfiguration(
        commandName: "fold",
        abstract: "Fold or unfold a foldable iOS Simulator (iPhone Duo), or report its posture.",
        discussion: """
        Sets the hinge like Device Hub's posture buttons and waits until \
        CoreDevice reports the matching display as active. Without an \
        argument, prints the current posture: the display that hosts the \
        interface, its orientation, and any Resize Mode session.

        Postures:
          closed   0°   — the cover (primary) display takes over
          open     180° — the inner display takes over
          half     130° — Device Hub's half-open preset
          0-180         — any hinge angle in degrees

        `closed` and `open` are confirmed: the command fails when the \
        expected display does not become active. At an intermediate angle \
        the active display depends on how the hinge got there, so the \
        command reports the display it observed. A fold also wakes a \
        locked device to its lock screen.

        A fold changes the screen geometry, so the cached describe-ui \
        snapshot is cleared; run `describe-ui` again before `tap @N`.

        Needs a simulator with more than one integrated display and the \
        devicectl of Xcode 26.6 or later.

        Examples:
          sim-use ios fold --device UDID            # report the posture
          sim-use ios fold open --device UDID       # unfold
          sim-use ios fold closed --json --device UDID
          sim-use ios fold 90 --device UDID
        """
    )

    @Argument(help: "closed, open, half, or a hinge angle 0-180. Omit to report the posture.")
    public var posture: String?

    @Option(name: .customLong("timeout"), help: "Seconds to wait for CoreDevice to confirm the change (default 6).")
    public var timeout: Double = 6

    @OptionGroup public var device: DeviceOptions

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        if let arg = try DeviceOptions.selectExplicit(device: device.device, udid: device.udid),
           PlatformRouter.looksLikeAndroid(arg) {
            throw CLIError(errorDescription: HIDKeyCommandHelp.androidUnsupportedMessage(verb: "ios fold", udid: arg))
        }
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func validate() throws {
        if let posture, FoldTarget(argument: posture) == nil {
            throw ValidationError("Posture must be closed, open, half, or a hinge angle from 0 to 180 (got '\(posture)').")
        }
        guard timeout > 0, timeout <= 60 else {
            throw ValidationError("--timeout must be between 0 and 60 seconds.")
        }
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        guard let requested = result.requested, let angle = result.hingeAngle else {
            return .line("Posture: \(result.posture.summary)")
        }
        let verb: String
        switch FoldTarget(argument: requested) {
        case .closed?: verb = "Folded closed"
        case .open?: verb = "Unfolded"
        default: verb = "Hinge set to \(ResizableAppSession.format(angle))°"
        }
        return .line("\(verb): \(result.posture.summary)")
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await performGlobalSetup(logger: logger)
        let udid = device.resolved

        guard let posture, let target = FoldTarget(argument: posture) else {
            let topology = try await PostureController.requireTopology(udid: udid, monitor: .shared)
            let session = await ResizableAppSessionMonitor.shared.state(for: udid).session
            return ExecutionResult(fold: nil, posture: PostureReport(topology: topology, session: session))
        }

        let outcome = try await PostureController.fold(udid: udid, target: target, timeout: timeout, logger: logger)
        return ExecutionResult(fold: outcome, posture: outcome.posture)
    }
}
