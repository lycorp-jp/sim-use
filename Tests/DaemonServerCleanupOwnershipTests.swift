// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
@testable import SimUseCore
import Darwin
import Foundation
import Testing

// Coverage for DaemonServer.cleanup()'s file ownership check.
//
// A daemon's socket/pidfile paths can be taken over while it is still
// running: `DaemonSocket.listen` unlinks + rebinds the socket path and
// the successor overwrites the pidfile. That happens whenever a client
// respawns past a wedged daemon, or `daemon start` is run twice. The
// orphaned predecessor keeps serving its already-accepted connections
// and eventually shuts down (idle timeout / SIGTERM) — at which point
// its cleanup must NOT delete the successor's socket/pidfile. Deleting
// them makes the live successor invisible (next client spawns a third
// daemon) and chains orphans, each pinning FBSimulatorControl state.
//
// Serialised for the usual reason: concurrent DaemonServers in one
// process interfere via signal handling.
@Suite("DaemonServer.cleanup ownership", .serialized)
@MainActor
struct DaemonServerCleanupOwnershipTests {

    private func makeTempDirectory() throws -> URL {
        let suffix = String(UUID().uuidString.prefix(6))
        let dir = URL(fileURLWithPath: "/tmp/sim-use-co-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    enum TestError: Error { case daemonNeverReady }

    private func startTestDaemon(
        udid: String,
        baseDirectory: URL
    ) async throws -> (DaemonPaths, Task<Void, Error>) {
        let paths = DaemonPaths(udid: udid, baseDirectory: baseDirectory)
        try paths.ensureBaseDirectory()
        let server = DaemonServer(udid: udid, idleTimeout: 30, paths: paths)
        let task = Task { try await server.run() }
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

    @Test("Shutdown after a path takeover leaves the successor's files in place")
    func takeoverSurvivesPredecessorShutdown() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let udid = "TEST-TAKEOVER-\(UUID().uuidString.prefix(8))"
        let (paths, task) = try await startTestDaemon(udid: udid, baseDirectory: tmp)
        defer { task.cancel() }

        // Connect BEFORE the takeover: an established connection keeps
        // working on the bound inode even after the path is unlinked,
        // exactly like a real client that raced the successor's bind.
        let fd = try DaemonSocket.connect(path: paths.socketURL.path)
        defer { Darwin.close(fd) }

        // Simulate the successor daemon taking over both paths. The
        // successor must be a LIVE process we own — ownership is only
        // honoured while the owner is alive (a dead owner's files are
        // stale garbage; see the dead-pid test below).
        let successor = Process()
        successor.executableURL = URL(fileURLWithPath: "/bin/sleep")
        successor.arguments = ["30"]
        try successor.run()
        defer { successor.terminate() }
        let foreignPid: pid_t = successor.processIdentifier
        try Data("\(foreignPid)\n".utf8).write(to: paths.pidfileURL)
        try FileManager.default.removeItem(at: paths.socketURL)
        FileManager.default.createFile(
            atPath: paths.socketURL.path,
            contents: Data("successor-socket".utf8)
        )

        // Stop the predecessor over the pre-takeover connection. The
        // blocking write/read must run OFF the main actor: the server
        // handles requests on the main actor, so a main-actor-blocking
        // readLine would deadlock the test against the daemon.
        var request = try JSONEncoder().encode(DaemonRequest(cmd: "_stop"))
        request.append(0x0A)
        let stopRequest = request
        let ack: Data? = await Task.detached {
            let writeResult = DaemonSocket.writeAll(fd: fd, data: stopRequest)
            guard writeResult.ok else { return nil }
            return DaemonSocket.readLine(fd: fd)
        }.value
        #expect(ack != nil)

        _ = try? await task.value

        // The successor's files must survive the predecessor's cleanup.
        #expect(paths.readPidfile() == foreignPid)
        let socketData = FileManager.default.contents(atPath: paths.socketURL.path)
        #expect(socketData == Data("successor-socket".utf8))
    }

    @Test("Takeover by a dead pid is cleaned up as stale on shutdown")
    func takeoverByDeadPidIsCleanedUp() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let udid = "TEST-DEADOWNER-\(UUID().uuidString.prefix(8))"
        let (paths, task) = try await startTestDaemon(udid: udid, baseDirectory: tmp)
        defer { task.cancel() }

        let fd = try DaemonSocket.connect(path: paths.socketURL.path)
        defer { Darwin.close(fd) }

        // Pidfile points at a pid that is certainly dead (above macOS
        // pid_max). Deferring to a dead "owner" would strand stale
        // files that the next client only clears via its liveness
        // probe — and a recycled pid could even fake a live daemon.
        let deadPid: pid_t = 9_999_997
        try Data("\(deadPid)\n".utf8).write(to: paths.pidfileURL)
        try FileManager.default.removeItem(at: paths.socketURL)
        FileManager.default.createFile(
            atPath: paths.socketURL.path,
            contents: Data("stale-socket".utf8)
        )

        var request = try JSONEncoder().encode(DaemonRequest(cmd: "_stop"))
        request.append(0x0A)
        let stopRequest = request
        let ack: Data? = await Task.detached {
            let writeResult = DaemonSocket.writeAll(fd: fd, data: stopRequest)
            guard writeResult.ok else { return nil }
            return DaemonSocket.readLine(fd: fd)
        }.value
        #expect(ack != nil)

        _ = try? await task.value

        // Dead owner → stale files; the shutting-down daemon removes them.
        #expect(paths.readPidfile() == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
    }
}
