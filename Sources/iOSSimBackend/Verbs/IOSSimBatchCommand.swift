// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// iOS Simulator backend for the `batch` verb. iOS-only — the batch
/// runner shares an iOS HID session across steps to amortise per-event
/// cost. Android steps each round-trip through the bridge over
/// `adb forward`, so batching saves nothing and the iOS-specific
/// session plumbing has no Android equivalent. Reach via
/// `sim-use ios batch` only.
public struct IOSSimBatchCommand: SimUseExecutableCommand {
    public struct ExecutionResult: Codable {
        public let stepsExecuted: Int
        public init(stepsExecuted: Int) {
            self.stepsExecuted = stepsExecuted
        }
    }

    public static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract: "Execute ordered interaction steps using one iOS simulator/HID session.",
        discussion: """
        Batch executes multiple interaction steps in one command to reduce overhead.
        Steps are executed in order.

        Supported step commands:
          tap, swipe, gesture, touch, type, paste, button, key, key-sequence, key-combo

        Batch-only pseudo-step:
          sleep <seconds>

        Notes on `paste` inside batch:
          * Default Cmd+V path only — `--via-menu` is not supported as a
            batch step. Run `sim-use paste --via-menu` standalone instead.
          * `--stdin` is rejected. Pass text inline (`paste 'hello'`) or
            via `--file <path>`.

        Examples:
          sim-use ios batch --udid SIMULATOR_UDID --step "tap --id BackButton" --step "type 'hello'"
          sim-use ios batch --udid SIMULATOR_UDID --file steps.txt
          cat steps.txt | sim-use ios batch --udid SIMULATOR_UDID --stdin
        """
    )

    @OptionGroup public var device: DeviceOptions

    @Option(name: .customLong("step"), help: "Step to execute. Repeat for multiple steps.")
    public var steps: [String] = []

    @Option(name: .customLong("file"), help: "Read steps from a file (one step per line).")
    public var file: String?

    @Flag(name: .customLong("stdin"), help: "Read steps from stdin (one step per line).")
    public var useStdin: Bool = false

    @Option(name: .customLong("ax-cache"), help: "Accessibility snapshot cache policy for selector-based taps: perBatch reuses one snapshot for the whole run, perStep refetches at each step, none never caches. --wait-timeout polling always refetches.")
    public var axCachePolicy: AXCachePolicy = .perBatch

    @Option(name: .customLong("type-submission"), help: "Type step submission mode.")
    public var typeSubmissionMode: TypeSubmissionMode = .chunked

    @Option(name: .customLong("type-chunk-size"), help: "Maximum HID events per chunk when type-submission is chunked.")
    public var typeChunkSize: Int = 200

    @Flag(name: .customLong("continue-on-error"), help: "Continue executing later steps even if one step fails.")
    public var continueOnError: Bool = false

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for selector-based elements before failing (0 = no waiting).")
    public var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active.")
    public var pollInterval: Double = 0.25

    @Flag(name: .customLong("verbose"), help: "Enable verbose logging to stderr.")
    public var verbose: Bool = false

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        if let arg = try DeviceOptions.selectExplicit(device: device.device, udid: device.udid),
           PlatformRouter.looksLikeAndroid(arg) {
            // `batch` shares an iOS HID session across steps; there is
            // no Android equivalent (every Android step round-trips
            // through the bridge over `adb forward` and can be issued
            // as a standalone `sim-use` invocation). Reject the UDID at
            // parse/resolve time so an Android caller doesn't fall
            // into the daemon spawn path with an opaque "not found"
            // error.
            //
            // CLIError so the message survives our run() catch — see
            // IOSSimKeyCommand for the rationale.
            throw CLIError(errorDescription:
                """
                `batch` is not supported on Android (\(arg)). The batch runner shares an iOS \
                HID session across steps to amortise per-event cost — Android steps each \
                round-trip through the bridge over `adb forward`, so batching saves nothing \
                and the iOS-specific session plumbing has no Android equivalent. Run the \
                steps as separate `sim-use` invocations instead, e.g. `sim-use tap … && \
                sim-use type … && sim-use button back`.
                """
            )
        }
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    // The daemon child process runs with stdin pinned to /dev/null and
    // its CWD is the daemon's, not the caller's, so two batch input
    // sources cannot survive a daemon round-trip:
    //   * `--stdin` reads zero lines on the daemon side and surfaces as
    //     the opaque `ArgumentParser.ValidationError error 1` wrapper
    //     around `"No executable steps found."` (LINEIOS-216940).
    //   * `--file <relative>` resolves against the daemon's CWD instead
    //     of the caller's, so a working path on the client side becomes
    //     a missing file once forwarded.
    // Bypass the daemon for both modes; `--step` flags remain
    // daemon-routable as today.
    public var daemonBypass: Bool { useStdin || file != nil }

    public func validate() throws {
        try Self.validateOptions(
            steps: steps,
            file: file,
            useStdin: useStdin,
            typeChunkSize: typeChunkSize,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval
        )
    }

    public static func validateOptions(
        steps: [String],
        file: String?,
        useStdin: Bool,
        typeChunkSize: Int,
        waitTimeout: Double,
        pollInterval: Double
    ) throws {
        let sourceCount = [!steps.isEmpty, file != nil, useStdin].filter { $0 }.count
        guard sourceCount == 1 else {
            throw ValidationError("Specify exactly one step source: --step, --file, or --stdin.")
        }

        guard typeChunkSize > 0 else {
            throw ValidationError("--type-chunk-size must be greater than 0.")
        }

        guard waitTimeout >= 0 else {
            throw ValidationError("--wait-timeout must be non-negative.")
        }

        if waitTimeout > 0 {
            guard pollInterval > 0 else {
                throw ValidationError("--poll-interval must be greater than 0 when --wait-timeout is active.")
            }
        }
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger(writeToStdErr: verbose)
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let stepLines = try loadStepLines()
        if stepLines.isEmpty {
            // CLIError because this throw is reached from `execute()`,
            // whose error path is the SimUseExecutableCommand.run()
            // catch — ValidationError there degrades to the opaque
            // NSError bridge wrapper. See IOSSimKeyCommand for the
            // full rationale.
            throw CLIError(errorDescription: "No executable steps found.")
        }

        let context = await MainActor.run {
            BatchContext(
                simulatorUDID: device.resolved,
                axCachePolicy: axCachePolicy,
                typeSubmissionMode: typeSubmissionMode,
                typeChunkSize: typeChunkSize,
                waitTimeout: waitTimeout,
                pollInterval: pollInterval
            )
        }

        let session = try await HIDInteractor.makeSession(for: device.resolved, logger: logger)
        let runner = await MainActor.run { BatchPlanRunner(session: session, logger: logger) }

        var failures: [String] = []

        for (index, line) in stepLines.enumerated() {
            var stepName = "<unparsed>"
            do {
                // Step boundary: `--ax-cache perStep` invalidates its
                // snapshot here so selector taps see the current UI.
                await context.beginStep()
                let tokens = try ShellTokenizer.tokenize(line)
                stepName = tokens.first ?? "<empty>"
                let primitives = try await BatchStepParser.parseStepTokens(
                    tokens,
                    globalUDID: device.resolved,
                    context: context,
                    logger: logger
                )
                try await runner.run(BatchPlan(primitives: primitives))
            } catch {
                if continueOnError {
                    failures.append("Step \(index + 1) failed: [\(stepName)] -> \(error.localizedDescription)")
                } else {
                    throw CLIError(errorDescription: "Step \(index + 1) failed: [\(stepName)]\n\(error.localizedDescription)")
                }
            }
        }

        if !failures.isEmpty {
            let failureMessage = failures.joined(separator: "\n")
            throw CLIError(errorDescription: "Batch completed with \(failures.count) failure(s):\n\(failureMessage)")
        }

        return ExecutionResult(stepsExecuted: stepLines.count)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("✓ Batch completed successfully (\(result.stepsExecuted) steps)")
    }

    private func loadStepLines() throws -> [String] {
        let rawLines: [String]
        if !steps.isEmpty {
            rawLines = steps
        } else if let file {
            let contents: String
            do {
                contents = try String(contentsOfFile: file, encoding: .utf8)
            } catch {
                // CLIError so the message survives our run() catch —
                // loadStepLines is reached from execute(), not validate.
                throw CLIError(errorDescription: "Failed to read step file '\(file)': \(error.localizedDescription)")
            }
            rawLines = contents.components(separatedBy: .newlines)
        } else {
            rawLines = readStdinLines()
        }

        return rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func readStdinLines() -> [String] {
        var lines: [String] = []
        while let line = readLine() {
            lines.append(line)
        }
        return lines
    }
}