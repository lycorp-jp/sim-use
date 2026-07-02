// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
@testable import SimUseCore
import ArgumentParser
import Darwin
import Foundation
import Testing

// D3: the idle timer counts from the last reset (request start / response
// end), not from actual idleness, and its fire handler never consulted
// the `activeRequests` counter. A single daemon-routed request that runs
// longer than idleTimeout (e.g. `tap --wait-timeout 700`, or a long
// `batch` sent as `--step`s) therefore tripped the timer *mid-execution*:
// `triggerShutdown` resumed the shutdown continuation during the request's
// `await`, `cleanup()` tore down the socket/pidfile while the request was
// still in flight, and in a real process `run()` returning exits it out
// from under the unfinished command.
//
// The fix defers shutdown while a request is executing. This suite drives
// a deliberately slow command through a real DaemonServer whose idle
// timeout is far shorter than the command, and asserts the daemon has NOT
// cleaned up its socket by the time the command finishes.

// Shared knobs for the slow probe command below. MainActor so the daemon
// dispatch (MainActor) and the test body touch them safely.
@MainActor
private enum SlowProbeState {
    static var socketPath = ""
    static var sleepNanos: UInt64 = 0

    static func configure(socketPath: String, sleepNanos: UInt64) {
        self.socketPath = socketPath
        self.sleepNanos = sleepNanos
    }
}

/// A daemon-dispatchable command that sleeps well past the server's idle
/// timeout, then reports whether the daemon's own socket still exists.
/// If the idle timer wrongly fired mid-request, `cleanup()` will have
/// unlinked the socket before this returns.
private struct SlowProbeCommand: SimUseExecutableCommand {
    struct Payload: Codable { var socketStillPresent: Bool }
    typealias ExecutionResult = Payload

    static let configuration = CommandConfiguration(commandName: "slow-probe")
    var jsonOutput: Bool { false }

    func execute() async throws -> Payload {
        let (nanos, path) = await MainActor.run {
            (SlowProbeState.sleepNanos, SlowProbeState.socketPath)
        }
        try await Task.sleep(nanoseconds: nanos)
        return Payload(socketStillPresent: FileManager.default.fileExists(atPath: path))
    }

    func format(_ result: Payload) -> CommandOutput {
        .line("\(result.socketStillPresent)")
    }
}

@Suite("DaemonServer idle timer respects in-flight requests", .serialized)
@MainActor
struct DaemonServerIdleTimerTests {

    private func makeTempDirectory() throws -> URL {
        let suffix = String(UUID().uuidString.prefix(6))
        let dir = URL(fileURLWithPath: "/tmp/sim-use-idle-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct Envelope: Decodable {
        let ok: Bool
        let data: SlowProbeCommand.Payload
    }

    @Test("a request that outlasts the idle timeout is not shut down mid-flight")
    func idleTimerDefersWhileRequestInFlight() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let udid = "TEST-IDLE-\(UUID().uuidString.prefix(8))"
        let paths = DaemonPaths(udid: udid, baseDirectory: tmp)
        try paths.ensureBaseDirectory()

        // Command runs 0.5 s; idle timeout is 0.2 s. A buggy timer fires
        // (twice) during the command and tears the socket down at 0.2 s.
        SlowProbeState.configure(socketPath: paths.socketURL.path, sleepNanos: 500_000_000)

        try await withExclusiveCommandParser({ _ in SlowProbeCommand() }) {
            let server = DaemonServer(udid: udid, idleTimeout: 0.2, paths: paths)
            let serverTask = Task { try await server.run() }

            // Wait for bind + listen + pidfile.
            var ready = false
            for _ in 0..<50 {
                if FileManager.default.fileExists(atPath: paths.socketURL.path),
                   paths.readPidfile() != nil {
                    ready = true
                    break
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(ready)

            // Send one request off the main actor — the server serves on
            // the main actor, so a main-actor-blocking readLine here would
            // deadlock against it.
            let fd = try DaemonSocket.connect(path: paths.socketURL.path)
            defer { Darwin.close(fd) }
            var request = try JSONEncoder().encode(DaemonRequest(cmd: "slow-probe"))
            request.append(0x0A)
            let requestData = request
            let responseLine: Data? = await Task.detached {
                guard DaemonSocket.writeAll(fd: fd, data: requestData).ok else { return nil }
                return DaemonSocket.readLine(fd: fd)
            }.value

            let line = try #require(responseLine, "daemon sent no response")
            let envelope = try JSONDecoder().decode(Envelope.self, from: line)
            #expect(envelope.ok)
            #expect(envelope.data.socketStillPresent,
                    "idle timer fired mid-request: the daemon cleaned up its socket before the command finished")

            // Once the request is done the daemon should idle out on its
            // own; give it room to shut down cleanly.
            _ = try? await serverTask.value
        }
    }
}
