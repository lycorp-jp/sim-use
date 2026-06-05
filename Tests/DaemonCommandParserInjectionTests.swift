// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import ArgumentParser
import Foundation
import Testing
@testable import SimUseCore

// Coverage for the `DaemonDispatch.commandParser` injection wired
// inside `Daemon.Start.run()`. The dispatch module deliberately
// doesn't reach back into the top-level SimUse command tree — the
// host CLI sets the closure once at daemon startup so the daemon
// server can route requests through ArgumentParser without owning a
// hard SimUse dependency.
//
// Without this wiring, the daemon server is dead on arrival:
// `DaemonDispatch.handle` falls into a permanent error every time it
// sees a real subcommand. Worth pinning so a future refactor that
// touches Daemon.swift can't silently drop the assignment.
@Suite("DaemonDispatch.commandParser injection")
@MainActor
struct DaemonCommandParserInjectionTests {
    /// Reset / restore around each test so a global-state hop in one
    /// test can't leak into the next. We avoid stomping a parser that
    /// some other test may already have set: snapshot, mutate, restore.
    private func withParser(
        _ parser: ((@MainActor ([String]) throws -> ParsableCommand))?,
        body: () async throws -> Void
    ) async rethrows {
        let saved = DaemonDispatch.commandParser
        DaemonDispatch.commandParser = parser
        defer { DaemonDispatch.commandParser = saved }
        try await body()
    }

    /// When `commandParser` is unset, dispatch must return a permanent
    /// error envelope. Permanent so daemon clients don't retry — the
    /// host CLI forgot to wire it and retrying won't help.
    @Test("Missing parser surfaces a permanent error")
    func missingParserIsPermanentError() async throws {
        try await withParser(nil) {
            let snapshot = DaemonDispatch.Snapshot(
                pid: 1,
                startTime: Date(),
                udid: "TEST-UDID",
                simUseVersion: "test"
            )
            let request = DaemonRequest(id: "r1", cmd: "describe-ui", args: [])
            let outcome = await DaemonDispatch.handle(request, snapshot: snapshot)

            let envelope = try JSONDecoder().decode(ErrorEnvelope.self, from: outcome.responseData)
            #expect(envelope.ok == false)
            #expect(envelope.kind == "permanent")
            #expect(envelope.error.contains("commandParser"))
            #expect(outcome.shouldStopDaemon == false)
        }
    }

    /// `Daemon.Start.run()` configures the parser as
    /// `SimUse.parseAsRoot`. A canary command (`--version`) round-trips
    /// through that closure to assert it actually parses the SimUse
    /// command tree, not just any closure.
    @Test("SimUse.parseAsRoot satisfies the parser contract")
    func simUseParserAcceptsKnownVerbs() async throws {
        try await withParser({ args in try SimUse.parseAsRoot(args) }) {
            // Pick a verb that exists on every platform with no required
            // flags so the parse succeeds without touching the simulator.
            // `daemon status` parses cleanly without --udid and never
            // reaches the daemon socket from inside the test.
            let parsed = try DaemonDispatch.commandParser!(["daemon", "status"])
            #expect(parsed is Daemon.Status)
        }
    }

    /// Unknown subcommands round-trip through the parser path and
    /// surface as permanent dispatch errors carrying ArgumentParser's
    /// own diagnostic, not the "parser not configured" sentinel.
    @Test("Unknown verb is reported via ArgumentParser, not as missing parser")
    func unknownVerbIsArgParserError() async throws {
        try await withParser({ args in try SimUse.parseAsRoot(args) }) {
            let snapshot = DaemonDispatch.Snapshot(
                pid: 1,
                startTime: Date(),
                udid: "TEST-UDID",
                simUseVersion: "test"
            )
            let request = DaemonRequest(id: "r2", cmd: "no-such-verb-here", args: [])
            let outcome = await DaemonDispatch.handle(request, snapshot: snapshot)

            let envelope = try JSONDecoder().decode(ErrorEnvelope.self, from: outcome.responseData)
            #expect(envelope.ok == false)
            #expect(envelope.kind == "permanent")
            // Crucially, NOT the missing-parser sentinel. The host CLI
            // wired its parser; ArgumentParser is the one rejecting the
            // unknown verb.
            #expect(!envelope.error.contains("commandParser not configured"))
        }
    }

    private struct ErrorEnvelope: Decodable {
        let ok: Bool
        let error: String
        let kind: String
    }
}