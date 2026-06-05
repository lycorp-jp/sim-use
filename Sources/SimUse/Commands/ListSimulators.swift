// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import iOSSimBackend
import SimUseCore

struct ListSimulators: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List iOS Simulators (legacy; use 'sim-use devices' for cross-platform listing).",
        discussion: """
        Tip: `sim-use devices` is the cross-platform replacement, listing
        iOS Simulators and Android devices side-by-side with a structured
        `--json` envelope that's easier to consume than this command's
        formatted string array. This command is preserved for scripts
        already pinning to it.
        """
    )

    @Flag(name: .customLong("json"), help: "Emit the simulator list as compact JSON (one array of strings).")
    var jsonOutput: Bool = false

    struct ExecutionResult: Codable {
        let simulators: [String]
    }

    func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()

        try await performGlobalSetup(logger: logger)

        let simulatorSet = try await getSimulatorSet(
            deviceSetPath: nil,
            logger: logger,
            reporter: EmptyEventReporter.shared
        )

        return ExecutionResult(simulators: simulatorSet.allSimulators.map { $0.description })
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        let stdout = result.simulators.map { $0 + "\n" }.joined()
        let stderr = "Tip: 'sim-use devices' lists both iOS Simulators and Android devices.\n"
        return CommandOutput(stdout: stdout, stderr: stderr)
    }
}