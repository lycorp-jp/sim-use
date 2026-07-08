// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import ArgumentParser
import Foundation
import Testing
@testable import SimUseCore

// MARK: - Fixtures

/// Minimal `SimUseExecutableCommand` whose `resolveDeferredArguments`
/// flips a flag we can read back inside `execute()`. If the daemon-side
/// dispatcher forgets to call resolveDeferredArguments before execute,
/// `executedSawResolved` will report false and the test fails.
private struct FakeDaemonCommand: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(commandName: "fake-daemon-cmd")

    @Flag(name: .customLong("json"))
    var jsonOutput: Bool = false

    /// Toggled by resolveDeferredArguments(); read by execute().
    var resolveCalled: Bool = false

    /// Lets a test simulate the resolver throwing (e.g. "no booted
    /// simulator") so we can verify `executeAsDaemonResponse`
    /// propagates the failure instead of running execute() blindly.
    var resolveShouldThrow: Bool = false

    var simulatorUDIDForDaemon: String? { "FAKE-UDID" }

    mutating func resolveDeferredArguments() throws {
        if resolveShouldThrow {
            throw ResolverProbe.simulated
        }
        resolveCalled = true
    }

    func execute() async throws -> FakeResult {
        FakeResult(resolveWasCalledBeforeExecute: resolveCalled)
    }

    func format(_ result: FakeResult) -> CommandOutput { CommandOutput() }

    struct FakeResult: Codable, Equatable {
        let resolveWasCalledBeforeExecute: Bool
    }
}

private struct FakeAdvisoryCommand: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(commandName: "fake-advisory-cmd")

    @Flag(name: .customLong("json"))
    var jsonOutput: Bool = false

    func execute() async throws -> FakeResult {
        FakeResult()
    }

    func format(_ result: FakeResult) -> CommandOutput { CommandOutput() }

    struct FakeResult: Codable, CommandAdvisoryProviding {
        var commandAdvisory: CommandAdvisory? {
            CommandAdvisory(kind: .fullScreenTapTarget, message: "check target")
        }
    }
}

private enum ResolverProbe: LocalizedError {
    case simulated
    var errorDescription: String? { "simulated resolver failure" }
}

// MARK: - Tests

@Suite("SimUseExecutableCommand.executeAsDaemonResponse")
struct DaemonExecuteOrderTests {
    @Test("calls resolveDeferredArguments before execute() so daemon-side parses see resolved state")
    func resolveRunsBeforeExecute() async throws {
        var cmd = FakeDaemonCommand()
        let data = try await cmd.executeAsDaemonResponse(id: nil)

        struct Envelope: Decodable {
            let data: FakeDaemonCommand.FakeResult
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        #expect(envelope.data.resolveWasCalledBeforeExecute)
    }

    @Test("propagates resolveDeferredArguments failure without invoking execute()")
    func resolveFailureSkipsExecute() async throws {
        var cmd = FakeDaemonCommand()
        cmd.resolveShouldThrow = true

        do {
            _ = try await cmd.executeAsDaemonResponse(id: nil)
            Issue.record("expected the resolver error to propagate")
        } catch let error as ResolverProbe {
            #expect(error == .simulated)
        }
    }

    @Test("daemon response carries command advisory outside data")
    func commandAdvisoryIsTopLevel() async throws {
        var cmd = FakeAdvisoryCommand()
        let data = try await cmd.executeAsDaemonResponse(id: nil)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text == #"{"advisory":{"kind":"full_screen_tap_target","message":"check target"},"data":{},"ok":true}"#)
    }
}
