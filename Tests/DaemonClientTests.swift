// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
@testable import SimUseCore
import Darwin
import Foundation
import Testing

// MARK: - Fixtures

// Unix-domain socket paths are capped at 104 bytes on Darwin
// (sockaddr_un.sun_path). macOS's default `$TMPDIR` lives under
// `/var/folders/.../T/` which already eats ~50 chars, so compose the
// per-test base under `/tmp` with a short suffix to leave headroom
// for the UDID segment and `.sock` peer.
private func makeTempDirectory() throws -> URL {
    let suffix = String(UUID().uuidString.prefix(6))
    let dir = URL(fileURLWithPath: "/tmp/sim-use-ct-\(suffix)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func removeTempDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Version comparator

@Suite("DaemonClient.shouldRestartForVersion")
struct DaemonClientVersionComparatorTests {
    @Test("Identical versions do not trigger restart")
    func matching() {
        #expect(!DaemonClient.shouldRestartForVersion(daemon: "c36e0fe", current: "c36e0fe"))
        #expect(!DaemonClient.shouldRestartForVersion(daemon: "v1.6.0", current: "v1.6.0"))
    }

    @Test("Different versions trigger restart")
    func mismatching() {
        #expect(DaemonClient.shouldRestartForVersion(daemon: "c36e0fe", current: "4e64840"))
        #expect(DaemonClient.shouldRestartForVersion(daemon: "c36e0fe", current: "c36e0fe-dirty"))
        #expect(DaemonClient.shouldRestartForVersion(daemon: "v1.6.0", current: "v1.7.0"))
    }

    @Test("Whitespace variants treated as equal")
    func whitespaceIsIgnored() {
        #expect(!DaemonClient.shouldRestartForVersion(daemon: " c36e0fe", current: "c36e0fe "))
        #expect(!DaemonClient.shouldRestartForVersion(daemon: "c36e0fe\n", current: "c36e0fe"))
    }

    @Test("Empty version on either side is inconclusive, never triggers restart")
    func emptyInconclusive() {
        // Guard against a broken VersionPlugin output causing a
        // restart loop when neither side can identify itself.
        #expect(!DaemonClient.shouldRestartForVersion(daemon: "", current: "c36e0fe"))
        #expect(!DaemonClient.shouldRestartForVersion(daemon: "c36e0fe", current: ""))
        #expect(!DaemonClient.shouldRestartForVersion(daemon: "", current: ""))
        #expect(!DaemonClient.shouldRestartForVersion(daemon: "   ", current: "c36e0fe"))
    }
}

// MARK: - ensureCompatibleDaemon integration

// Serialised: DaemonServer installs a SIGTERM/SIGINT dispatch source
// on every run, and two concurrent servers in the same process step on
// each other's signal handling. One test at a time keeps the fixture
// isolated.
@Suite("DaemonClient.ensureCompatibleDaemon", .serialized)
@MainActor
struct DaemonClientEnsureCompatibleDaemonTests {

    // Spin up a real DaemonServer with an injected fake version, in
    // an isolated base directory. Returns the server task so callers
    // can wait for it to exit after a stop.
    private func startTestDaemon(
        udid: String,
        baseDirectory: URL,
        version: String
    ) async throws -> (DaemonPaths, Task<Void, Error>) {
        let paths = DaemonPaths(udid: udid, baseDirectory: baseDirectory)
        try paths.ensureBaseDirectory()
        let server = DaemonServer(
            udid: udid,
            idleTimeout: 30,
            paths: paths,
            simUseVersion: version
        )
        let task = Task { try await server.run() }
        // Give the server a moment to bind + listen + write pidfile.
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: paths.socketURL.path),
               paths.readPidfile() != nil {
                return (paths, task)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel()
        throw TestError.daemonNeverReady
    }

    enum TestError: Error { case daemonNeverReady }

    @Test("Matching version leaves daemon running, no restart")
    func matchingVersionNoop() async throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let udid = "TEST-MATCH-\(UUID().uuidString.prefix(8))"
        let (paths, task) = try await startTestDaemon(
            udid: udid,
            baseDirectory: tmp,
            version: "bench-match"
        )
        defer { task.cancel() }

        let pidBefore = paths.readPidfile()
        #expect(pidBefore != nil)

        let restarted = await DaemonClient.ensureCompatibleDaemon(
            paths: paths,
            currentVersion: "bench-match"
        )
        #expect(restarted == false)
        #expect(paths.readPidfile() == pidBefore)
        #expect(FileManager.default.fileExists(atPath: paths.socketURL.path))

        // Clean shutdown so the test's deferred cleanup is graceful.
        await DaemonClient.stopDaemon(paths: paths, timeout: 2.0)
        _ = try? await task.value
    }

    @Test("Mismatched version stops the daemon and cleans up its files")
    func mismatchedVersionTriggersStop() async throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let udid = "TEST-MISMATCH-\(UUID().uuidString.prefix(8))"
        let (paths, task) = try await startTestDaemon(
            udid: udid,
            baseDirectory: tmp,
            version: "bench-old"
        )
        defer { task.cancel() }

        let restarted = await DaemonClient.ensureCompatibleDaemon(
            paths: paths,
            currentVersion: "bench-new"
        )
        #expect(restarted == true)

        // Give the DaemonServer's main-actor shutdown path a tick to
        // finalise cleanup before asserting filesystem state.
        for _ in 0..<25 {
            if !FileManager.default.fileExists(atPath: paths.socketURL.path),
               paths.readPidfile() == nil {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
        #expect(paths.readPidfile() == nil)

        _ = try? await task.value
    }

    @Test("No daemon running is a no-op")
    func noDaemonRunning() async throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let paths = DaemonPaths(udid: "TEST-NONE", baseDirectory: tmp)
        try paths.ensureBaseDirectory()

        let restarted = await DaemonClient.ensureCompatibleDaemon(
            paths: paths,
            currentVersion: "bench-new"
        )
        #expect(restarted == false)
    }

    @Test("SIM_USE_DAEMON_VERSION_CHECK=0 bypasses the gate entirely")
    func envOptOut() async throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let udid = "TEST-OPTOUT-\(UUID().uuidString.prefix(8))"
        let (paths, task) = try await startTestDaemon(
            udid: udid,
            baseDirectory: tmp,
            version: "bench-old"
        )
        defer { task.cancel() }

        setenv("SIM_USE_DAEMON_VERSION_CHECK", "0", 1)
        defer { unsetenv("SIM_USE_DAEMON_VERSION_CHECK") }

        let restarted = await DaemonClient.ensureCompatibleDaemon(
            paths: paths,
            currentVersion: "bench-new"
        )
        #expect(restarted == false)
        // Daemon is still up despite version mismatch because gate is disabled.
        #expect(FileManager.default.fileExists(atPath: paths.socketURL.path))

        await DaemonClient.stopDaemon(paths: paths, timeout: 2.0)
        _ = try? await task.value
    }
}