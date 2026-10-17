// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SimUseCore

// A per-device daemon is keyed by UDID alone, but what it talks to can
// depend on the environment it was started in (for Android, which adb
// server). A warm daemon started against one connection must not serve
// a client configured for another, so the reuse gate compares the
// connection identity alongside the version.

@Suite("DaemonClient.shouldRestartForConnection")
struct DaemonConnectionComparatorTests {
    @Test("A target without a connection identity never restarts")
    func noIdentity() {
        #expect(!DaemonClient.shouldRestartForConnection(daemon: nil, current: nil))
        #expect(!DaemonClient.shouldRestartForConnection(daemon: "adb=A", current: nil))
    }

    @Test("Same identity keeps the daemon")
    func same() {
        #expect(!DaemonClient.shouldRestartForConnection(daemon: "adb=A", current: "adb=A"))
    }

    @Test("Different identity restarts the daemon")
    func different() {
        #expect(DaemonClient.shouldRestartForConnection(daemon: "adb=A", current: "adb=B"))
    }

    @Test("A daemon that reports no identity cannot prove it matches")
    func legacyDaemon() {
        #expect(DaemonClient.shouldRestartForConnection(daemon: nil, current: "adb=A"))
    }
}

// The `_ping` gate cannot vet a daemon whose probe times out (it serves
// one connection at a time, so a long command from another client blocks
// the probe). The daemon therefore also checks the identity carried on
// each business request before it parses or runs it.
@Suite("DaemonDispatch request connection gate")
@MainActor
struct DaemonDispatchConnectionGateTests {
    private func snapshot(identity: String?) -> DaemonDispatch.Snapshot {
        DaemonDispatch.Snapshot(
            pid: 1,
            startTime: Date(),
            udid: "emulator-5554",
            simUseVersion: "gate-test",
            connectionIdentity: identity
        )
    }

    private struct ErrorEnvelope: Decodable {
        let ok: Bool
        let error: String
        let kind: DaemonErrorKind
        let hint: String?
    }

    private struct PingEnvelope: Decodable {
        let ok: Bool
        let data: DaemonPingData
    }

    @Test("Matching identities pass the gate")
    func matching() {
        let request = DaemonRequest(cmd: "tap", connectionIdentity: "adb=A")
        #expect(DaemonDispatch.connectionMismatchOutcome(request, snapshot: snapshot(identity: "adb=A")) == nil)
    }

    @Test("A target without an identity passes the gate")
    func noIdentity() {
        let request = DaemonRequest(cmd: "tap")
        #expect(DaemonDispatch.connectionMismatchOutcome(request, snapshot: snapshot(identity: nil)) == nil)
    }

    @Test(
        "Any other combination is refused",
        arguments: [
            ("adb=B" as String?, "adb=A" as String?),
            (nil, "adb=A"),
            ("adb=A", nil),
        ]
    )
    func mismatch(requestIdentity: String?, daemonIdentity: String?) throws {
        let request = DaemonRequest(id: "r1", cmd: "tap", connectionIdentity: requestIdentity)
        let outcome = try #require(
            DaemonDispatch.connectionMismatchOutcome(request, snapshot: snapshot(identity: daemonIdentity))
        )
        #expect(!outcome.shouldStopDaemon)
        let envelope = try JSONDecoder().decode(ErrorEnvelope.self, from: outcome.responseData)
        #expect(!envelope.ok)
        #expect(envelope.kind == .permanent)
        #expect(envelope.error.contains("'tap' was not run"))
        // Identities can carry host addresses; they stay out of the output.
        #expect(!envelope.error.contains("adb="))
        #expect(envelope.hint?.contains("sim-use daemon stop --udid emulator-5554") == true)
    }

    // The gate runs before `DaemonDispatch.commandParser` is read, so this
    // does not depend on (or race) the parser other suites install.
    @Test("handle refuses a mismatched business request before parsing it")
    func handleRefusesBeforeParsing() async throws {
        let request = DaemonRequest(cmd: "tap", args: ["--no-such-flag"], connectionIdentity: "adb=B")
        let outcome = await DaemonDispatch.handle(request, snapshot: snapshot(identity: "adb=A"))
        let envelope = try JSONDecoder().decode(ErrorEnvelope.self, from: outcome.responseData)
        #expect(envelope.error.contains("different device connection"))
    }

    @Test("Management commands are not gated")
    func managementBypassesGate() async throws {
        let request = DaemonRequest(cmd: DaemonProtocol.ManagementCommand.ping.rawValue)
        let outcome = await DaemonDispatch.handle(request, snapshot: snapshot(identity: "adb=A"))
        let envelope = try JSONDecoder().decode(PingEnvelope.self, from: outcome.responseData)
        #expect(envelope.ok)
        #expect(envelope.data.connectionIdentity == "adb=A")
    }
}

// Serialised: DaemonServer installs process-wide SIGTERM/SIGINT sources.
@Suite("DaemonClient.ensureCompatibleDaemon connection gate", .serialized)
@MainActor
struct DaemonConnectionGateTests {
    @Test("A warm daemon started for another connection is restarted")
    func switchedConnectionRestartsWarmDaemon() async throws {
        let (paths, task, dir) = try await startDaemon(connectionIdentity: "adb=tcp:192.0.2.10:5037")
        defer { try? FileManager.default.removeItem(at: dir) }

        let restarted = await DaemonClient.ensureCompatibleDaemon(
            paths: paths,
            currentVersion: "gate-test",
            currentConnectionIdentity: "adb=tcp:192.0.2.20:5037",
            probeTimeout: Self.probeTimeout
        )

        #expect(restarted)
        await waitForShutdown(paths)
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
        #expect(paths.readPidfile() == nil)
        _ = try? await task.value
    }

    @Test("A warm daemon for the same connection is reused")
    func sameConnectionKeepsWarmDaemon() async throws {
        let identity = "adb=tcp:192.0.2.10:5037"
        let (paths, task, dir) = try await startDaemon(connectionIdentity: identity)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pid = paths.readPidfile()

        let restarted = await DaemonClient.ensureCompatibleDaemon(
            paths: paths,
            currentVersion: "gate-test",
            currentConnectionIdentity: identity,
            probeTimeout: Self.probeTimeout
        )

        #expect(!restarted)
        #expect(paths.readPidfile() == pid)
        await DaemonClient.stopDaemon(paths: paths, timeout: 2.0)
        _ = try? await task.value
    }

    @Test("The version opt-out does not disable the connection check")
    func versionOptOutKeepsConnectionCheck() async throws {
        let (paths, task, dir) = try await startDaemon(connectionIdentity: "adb=tcp:192.0.2.10:5037")
        defer { try? FileManager.default.removeItem(at: dir) }

        let restarted = await DaemonClient.ensureCompatibleDaemon(
            paths: paths,
            currentVersion: "gate-test",
            currentConnectionIdentity: "adb=tcp:192.0.2.20:5037",
            environment: ["SIM_USE_DAEMON_VERSION_CHECK": "0"],
            probeTimeout: Self.probeTimeout
        )

        #expect(restarted)
        await waitForShutdown(paths)
        _ = try? await task.value
    }

    // MARK: - Fixtures

    /// These daemons run in the test process, and their accept source is
    /// on the main queue, which parallel suites keep busy for seconds on a
    /// loaded runner. With the 2 s production probe timeout the `_ping`
    /// timed out there, and the gate kept the daemon (CI, 2026-10-17).
    static let probeTimeout: TimeInterval = 30

    enum FixtureError: Error { case daemonNeverReady }

    private func startDaemon(connectionIdentity: String) async throws -> (DaemonPaths, Task<Void, Error>, URL) {
        // Short /tmp path: sockaddr_un.sun_path is ~104 bytes.
        let dir = URL(fileURLWithPath: "/tmp/sim-use-cg-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let udid = "emulator-\(Int.random(in: 5554...5680))"
        let paths = DaemonPaths(udid: udid, baseDirectory: dir)
        try paths.ensureBaseDirectory()
        let server = DaemonServer(
            udid: udid,
            idleTimeout: 30,
            paths: paths,
            simUseVersion: "gate-test",
            connectionIdentity: connectionIdentity
        )
        let task = Task { try await server.run() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: paths.socketURL.path), paths.readPidfile() != nil {
                return (paths, task, dir)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel()
        throw FixtureError.daemonNeverReady
    }

    private func waitForShutdown(_ paths: DaemonPaths) async {
        for _ in 0..<500 {
            if !FileManager.default.fileExists(atPath: paths.socketURL.path), paths.readPidfile() == nil { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
