// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import CompanionUtilities
import FBSimulatorControl
@preconcurrency import FBControlCore
import SimUseCore
import SimUseVideo

/// iOS Simulator backend for the `screenshot` verb. Mirrors the flag
/// surface of top-level `Screenshot` and is also reachable directly
/// as `sim-use ios screenshot`. The top-level command resolves the
/// target platform via `PlatformRouter` and forwards iOS UDIDs
/// through here.
public struct IOSSimScreenshotCommand: SimUseExecutableCommand {
    public struct ExecutionResult: Codable, CommandAdvisoryProviding {
        public let path: String
        /// Set when the capture was redirected to the "Resizable" display
        /// of an active resizable app session (issue #143). Excluded from
        /// the encoded `data` payload via `CodingKeys` — the envelope
        /// hoists it to the top-level `advisory` key; see
        /// `CommandAdvisoryProviding` for the contract.
        public var commandAdvisory: CommandAdvisory? = nil

        public init(path: String, commandAdvisory: CommandAdvisory? = nil) {
            self.path = path
            self.commandAdvisory = commandAdvisory
        }

        private enum CodingKeys: String, CodingKey {
            case path
        }
    }

    public static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a screenshot from the simulator display and save it as a PNG file"
    )

    @OptionGroup public var device: DeviceOptions

    @Option(help: "Output PNG file path. Defaults to 'Simulator Screenshot - <device name> - <timestamp>.png' in the current directory.")
    public var output: String?

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public var daemonBypass: Bool { true }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(
            stdout: result.path + "\n",
            stderr: "Screenshot saved to \(result.path)\n"
        )
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await performGlobalSetup(logger: logger)

        let trimmedUDID = device.resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUDID.isEmpty else {
            throw CLIError(errorDescription: "Simulator UDID cannot be empty. Use --udid to specify a simulator.")
        }

        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        guard let targetSimulator = simulatorSet.allSimulators.first(where: { $0.udid == trimmedUDID }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(trimmedUDID) not found.")
        }

        guard targetSimulator.state == .booted else {
            let stateDescription = FBiOSTargetStateStringFromState(targetSimulator.state)
            throw CLIError(errorDescription: "Simulator \(trimmedUDID) is not booted. Current state: \(stateDescription)")
        }

        let outputURL = try Self.prepareOutputURL(output: output, simulatorName: targetSimulator.name)

        // The main framebuffer — the only one the pinned idb exposes — is
        // not where the app is during a Resize Mode session (wallpaper
        // only, issue #143) or while a secondary integrated display is
        // active (dark; the unfolded iPhone Duo). Capture the routing
        // display through simctl instead. Work record:
        // docs/ai/010-display-routing/000-plan.md.
        switch await RoutingDisplayResolver.current(udid: trimmedUDID) {
        case .main:
            break
        case .resizable(let session, _):
            logger.info().log("Resizable app session active; capturing display \(session.displayUniqueID) via simctl")
            let pixelSize = try DisplayScreenshot.capture(
                udid: trimmedUDID, displayUniqueID: session.displayUniqueID, displayName: session.displayName, to: outputURL
            )
            return ExecutionResult(
                path: outputURL.path,
                commandAdvisory: ResizableAppSessionAdvisory.screenshot(session: session, pixelSize: pixelSize)
            )
        case .secondary(let display):
            logger.info().log("App is on secondary display \(display.name); capturing display \(display.uniqueID) via simctl")
            _ = try DisplayScreenshot.capture(
                udid: trimmedUDID, displayUniqueID: display.uniqueID, displayName: display.name, to: outputURL
            )
            return ExecutionResult(path: outputURL.path)
        }

        let screenshotData = try await VideoFrameUtilities.captureScreenshotData(from: targetSimulator)
        try screenshotData.write(to: outputURL)

        return ExecutionResult(path: outputURL.path)
    }

    /// Resolve the user-supplied `--output` argument into a concrete
    /// file URL using iOS naming conventions. Public so tests can
    /// pin the path expansion behaviour without spinning up an
    /// FBSimulator. Path semantics live in `OutputFilePath`, shared
    /// with the video verbs and the physical-device screenshot. The
    /// simulator name is user-editable free text (simctl accepts any
    /// name), so it is collapsed into a single safe path component —
    /// "My iPhone/Work" must not turn the default output into a
    /// directory hierarchy.
    public static func prepareOutputURL(output: String?, simulatorName: String) throws -> URL {
        let url = OutputFilePath.resolve(output: output) {
            "Simulator Screenshot - \(OutputFilePath.safeFilenameComponent(simulatorName)) - \(formatTimestamp(Date())).png"
        }
        try OutputFilePath.prepare(url)
        return url
    }

    /// Shared timestamp format used by both iOS and Android default
    /// filenames so paired screenshots from cross-platform sessions
    /// sort together.
    public static func formatTimestamp(_ date: Date) -> String {
        OutputFilePath.screenshotTimestamp(date)
    }

}