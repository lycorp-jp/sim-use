// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Darwin
import Foundation

/// Commands implementing this protocol split their side-effecting work
/// (`execute`) from their user-facing output rendering (`format`). The
/// default `run()` composes them so today's CLI behaviour is preserved
/// exactly. The future daemon server calls `execute` alone and serialises
/// the `ExecutionResult` over the wire; the daemon client then calls
/// `format(_:)` locally to reproduce identical terminal output.
///
/// When the `--json` flag is passed, the default `run()` bypasses
/// `format(_:)` and prints a uniform envelope as compact JSON:
///
///     {"ok": true, "data": <ExecutionResult>}
///     {"ok": false, "error": "...", "hint": "..."}
///
/// The envelope shape matches the daemon wire protocol (LINEIOS-216214)
/// so CLI `--json` output and daemon responses share one parser on the
/// agent side.
public protocol SimUseExecutableCommand: AsyncParsableCommand {
    associatedtype ExecutionResult: Codable

    /// Whether the caller requested compact JSON output. Satisfied by a
    /// `@Flag(name: .customLong("json")) var jsonOutput: Bool = false`
    /// on each conforming command so ArgumentParser exposes it as a
    /// standard CLI flag.
    var jsonOutput: Bool { get }

    /// Opt-out for commands whose output is binary / streaming /
    /// long-running (`screenshot`, `record-video`, `stream-video`) and
    /// does not fit the request-response envelope. Default false.
    var daemonBypass: Bool { get }

    /// Target simulator UDID, if the command is scoped to one. nil
    /// means "no UDID" (`init`, `list-simulators`) and causes the
    /// default `run()` to stay in-process.
    var simulatorUDIDForDaemon: String? { get }

    /// True for commands that own the daemon's process-liveness tracker
    /// (i.e. `app-state`, which reads/resets it directly). Dispatch
    /// skips its automatic per-command crash evaluation for these so the
    /// tracker isn't double-advanced. Default false.
    var managesLivenessState: Bool { get }

    func execute() async throws -> ExecutionResult
    func format(_ result: ExecutionResult) -> CommandOutput

    /// Hook that runs in the CLIENT process before the request is
    /// dispatched (daemon or in-process). Intended for cheap, opinionated
    /// advisories whose output must reach the user's terminal, not a
    /// daemon log file. Default implementation is a no-op.
    func clientPreflight() async

    /// Resolves any args that depend on runtime state (e.g. picking the
    /// booted simulator's UDID when `--udid` is omitted). Runs *after*
    /// ArgumentParser's `validate()` so the resolution can throw without
    /// being interpreted as a usage error, and *inside* `run()`'s
    /// `--json`-aware error path so the resulting error reaches the
    /// agent through the standard envelope. Default implementation is
    /// a no-op; commands that derive an effective UDID override it.
    mutating func resolveDeferredArguments() throws
}

extension SimUseExecutableCommand {
    // Protocol defaults.
    public var daemonBypass: Bool { false }
    public var simulatorUDIDForDaemon: String? { nil }
    public var managesLivenessState: Bool { false }
    public func clientPreflight() async {}
    public mutating func resolveDeferredArguments() throws {}

    public mutating func run() async throws {
        let perf = ProcessInfo.processInfo.environment["SIM_USE_CLIENT_PERF"] == "1"
        let tStart = DispatchTime.now()

        if jsonOutput {
            do {
                try resolveDeferredArguments()
                await clientPreflight()
                let resolved = try await resolveExecutionResult()
                try emitJSONSuccess(
                    resolved.result,
                    processAdvisory: resolved.processAdvisory,
                    advisory: resolved.advisory
                )
            } catch {
                emitJSONError(error)
                Darwin.exit(1)
            }
        } else {
            do {
                try resolveDeferredArguments()
                await clientPreflight()
                let resolved = try await resolveExecutionResult()
                let result = resolved.result
                let tResolved = DispatchTime.now()
                // Loud/level process-liveness banner goes ABOVE the
                // command output (e.g. the describe-ui App header) so an
                // agent driving via the default text surface can't miss a
                // crash signal (issue #81).
                if let processAdvisory = resolved.processAdvisory,
                   let banner = ProcessAdvisoryRenderer.banner(for: processAdvisory) {
                    FileHandle.standardOutput.write(Data((banner + "\n").utf8))
                }
                if let advisory = resolved.advisory {
                    FileHandle.standardOutput.write(Data((CommandAdvisoryRenderer.banner(for: advisory) + "\n").utf8))
                }
                let output = format(result)
                let tFormatted = DispatchTime.now()
                output.emit()
                let tEmitted = DispatchTime.now()

                if perf {
                    let resolveMs = Double(tResolved.uptimeNanoseconds &- tStart.uptimeNanoseconds) / 1_000_000
                    let formatMs = Double(tFormatted.uptimeNanoseconds &- tResolved.uptimeNanoseconds) / 1_000_000
                    let emitMs = Double(tEmitted.uptimeNanoseconds &- tFormatted.uptimeNanoseconds) / 1_000_000
                    FileHandle.standardError.write(Data(
                        String(format: "[perf] resolve=%.1fms format=%.1fms emit=%.1fms stdout=%dB\n",
                               resolveMs, formatMs, emitMs, output.stdout.utf8.count).utf8
                    ))
                }
                return
            } catch {
                // Text-mode error path. ArgumentParser would otherwise
                // print `Error: <localizedDescription>` and exit 1, but
                // it knows nothing about `HintProviding` so the
                // actionable suggestion would silently drop. Mirror its
                // format and tack a `Hint:` line on for hint-bearing
                // errors so agents reading stderr get the same fix-it
                // text the JSON envelope carries.
                FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                if let hint = (error as? HintProviding)?.hint {
                    FileHandle.standardError.write(Data("Hint: \(hint)\n".utf8))
                }
                Darwin.exit(1)
            }
        }
    }

    /// Route the command through the daemon if it's a candidate and a
    /// daemon is (or can be) running, else run the work in-process.
    /// Failures inside the daemon path are *not* retried in-process:
    /// they are surfaced verbatim so the user sees the same error the
    /// daemon would have produced.
    private func resolveExecutionResult() async throws -> (
        result: ExecutionResult,
        processAdvisory: ProcessAdvisory?,
        advisory: CommandAdvisory?
    ) {
        guard shouldUseDaemon, let udid = simulatorUDIDForDaemon else {
            // In-process (standalone) path has no persistent tracker, so
            // it carries no cross-command process advisory.
            let result = try await execute()
            return (result, nil, (result as? CommandAdvisoryProviding)?.commandAdvisory)
        }

        let perf = ProcessInfo.processInfo.environment["SIM_USE_CLIENT_PERF"] == "1"
        let t0 = DispatchTime.now()

        // Forward whatever the user typed (everything after `sim-use`),
        // plus an explicit --device when they did not pass one: the
        // daemon-side parse needs the resolved device id to skip
        // auto-resolution (the daemon process doesn't have the same
        // {1 booted simulator} contract the client just relied on).
        //
        // We forward the FULL argv tail (e.g. `["ios", "key", "40",
        // "--device", "X"]`) rather than splitting off the verb-name
        // as the daemon `cmd` field — iOS-only verbs live under
        // `sim-use ios <verb>`, so the daemon parser must see the
        // entire subcommand path to walk into `IOSSimCommand` first.
        let fullTail = DeviceResolver.injectingDeviceIfNeeded(
            Array(CommandLine.arguments.dropFirst(1)),
            device: udid
        )
        let commandName = fullTail.first ?? resolvedCommandName
        let trailingArgs = Array(fullTail.dropFirst())

        let responseData = try await DaemonClient.invoke(
            command: commandName,
            args: trailingArgs,
            udid: udid
        )
        let t1 = DispatchTime.now()

        let result: ExecutionResult
        let processAdvisory: ProcessAdvisory?
        let advisory: CommandAdvisory?
        do {
            let payload = try JSONDecoder().decode(DaemonClientSuccessPayload<ExecutionResult>.self, from: responseData)
            result = payload.data
            processAdvisory = payload.processAdvisory
            advisory = payload.advisory
        } catch {
            throw DaemonClientError.malformedResponse(underlying: error)
        }
        let t2 = DispatchTime.now()

        if perf {
            let daemonMs = Double(t1.uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000
            let decodeMs = Double(t2.uptimeNanoseconds &- t1.uptimeNanoseconds) / 1_000_000
            FileHandle.standardError.write(Data(
                String(format: "[perf] daemon-roundtrip=%.1fms decode=%.1fms payload=%dB\n",
                       daemonMs, decodeMs, responseData.count).utf8
            ))
        }

        return (result, processAdvisory, advisory)
    }

    /// Is this command eligible for daemon dispatch *right now*?
    private var shouldUseDaemon: Bool {
        if daemonBypass { return false }
        if ProcessInfo.processInfo.environment["SIM_USE_NO_DAEMON"] == "1" { return false }
        // Inside the daemon we must never recursively re-dispatch.
        if ProcessInfo.processInfo.environment["SIM_USE_IN_DAEMON"] == "1" { return false }
        return true
    }

    /// ArgumentParser-derived command name. Uses the explicit
    /// `commandName` if set; otherwise converts the struct name to
    /// kebab-case to match ArgumentParser's own convention
    /// (`DescribeUI` -> `describe-ui`, `KeyCombo` -> `key-combo`).
    private var resolvedCommandName: String {
        if let explicit = Self.configuration.commandName { return explicit }
        let name = String(describing: Self.self)
        var result = ""
        let chars = Array(name)
        for index in chars.indices {
            let c = chars[index]
            if c.isUppercase, index > 0 {
                let prev = chars[index - 1]
                let next: Character? = (index + 1 < chars.count) ? chars[index + 1] : nil
                // Insert a hyphen on the boundary between a lowercase
                // run and an uppercase letter, or in the middle of an
                // uppercase run that is about to transition back to
                // lowercase (so "DescribeUI" splits as "describe-ui"
                // rather than "describe-u-i").
                if prev.isLowercase || (next?.isLowercase == true) {
                    result.append("-")
                }
            }
            result.append(c.lowercased())
        }
        return result
    }

    private func emitJSONSuccess(
        _ result: ExecutionResult,
        processAdvisory: ProcessAdvisory?,
        advisory: CommandAdvisory?
    ) throws {
        try JSONEnvelopeWriter.writeSuccess(
            result,
            processAdvisory: processAdvisory,
            advisory: advisory
        )
    }

    private func emitJSONError(_ error: Error) {
        JSONEnvelopeWriter.writeError(error)
    }
}

/// File-level generic wrapper for decoding the `data` field of a daemon
/// success envelope. Kept outside the `SimUseExecutableCommand` default
/// implementation because Swift disallows nested types that reference a
/// generic function's type parameters.
public struct DaemonClientSuccessPayload<T: Decodable>: Decodable {
    public let data: T
    /// Process-liveness advisory carried under the `process` key, when
    /// the daemon attached one (issue #81). Absent on responses that
    /// predate the field or carry no event.
    public let processAdvisory: ProcessAdvisory?
    /// Per-command advisory carried under the `advisory` key.
    public let advisory: CommandAdvisory?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.data = try container.decode(T.self, forKey: .data)
        self.processAdvisory = try container.decodeIfPresent(ProcessAdvisory.self, forKey: .process)
        self.advisory = try container.decodeIfPresent(CommandAdvisory.self, forKey: .advisory)
    }

    private enum CodingKeys: String, CodingKey { case data, process, advisory }
}
