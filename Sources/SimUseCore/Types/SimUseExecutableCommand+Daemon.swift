// SPDX-License-Identifier: Apache-2.0
import Foundation

extension SimUseExecutableCommand {
    /// Daemon-side execute: runs the command's side-effecting work and
    /// returns the pre-encoded `DaemonSuccessResponse` bytes. Kept on the
    /// protocol so dispatch code can call it through `any SimUseExecutableCommand`
    /// without knowing the concrete `ExecutionResult` type.
    ///
    /// Mutating because deferred-argument resolution (e.g. picking the
    /// booted simulator's UDID) writes into the parsed instance before
    /// `execute()` can read it. The client-side `run()` extension
    /// performs the same step before dispatch; running it again here
    /// is idempotent for explicit `--udid` invocations and necessary
    /// when the daemon happens to dispatch a command that came in
    /// without the resolved value baked in.
    public mutating func executeAsDaemonResponse(id: String?, advisory: ProcessAdvisory? = nil) async throws -> Data {
        try resolveDeferredArguments()
        let result = try await execute()
        let envelope = DaemonSuccessResponse(id: id, data: result, advisory: advisory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }
}