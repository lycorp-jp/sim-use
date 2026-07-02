// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import Darwin
import Foundation
import Testing

// D2: a daemon request that fails AFTER the bytes are on the wire (the
// daemon received it, possibly executed a side-effecting verb, then
// dropped the connection) must NOT be blindly respawned + resent — that
// would risk running tap/type/swipe twice. sim-use's callers are agents,
// so the right move is to surface a typed "ambiguous outcome" error with
// a hint and let the agent re-observe and decide. Pre-delivery failures
// (connect/write) still respawn, since the command provably never ran.

// MARK: - Pure classifier

@Suite("DaemonClient fast-path failure classification")
struct DaemonClientFastPathClassificationTests {

    @Test("connect failure (DaemonSocketError) is pre-delivery → respawn")
    func connectFailureRespawns() {
        let err = DaemonSocketError(op: "connect", errno: ECONNREFUSED)
        #expect(DaemonClient.requestReachedDaemon(err) == false)
        guard case .respawn = DaemonClient.classifyFastPathFailure(err) else {
            Issue.record("expected .respawn")
            return
        }
    }

    @Test("write failure is pre-delivery → respawn")
    func writeFailureRespawns() {
        let err = DaemonClientError.transportFailure(op: "write", errno: EPIPE, message: "broken pipe")
        #expect(DaemonClient.requestReachedDaemon(err) == false)
        guard case .respawn = DaemonClient.classifyFastPathFailure(err) else {
            Issue.record("expected .respawn")
            return
        }
    }

    @Test("empty response is post-delivery → surface ambiguousExecution")
    func emptyResponseIsAmbiguous() {
        #expect(DaemonClient.requestReachedDaemon(DaemonClientError.emptyResponse) == true)
        guard case .surface(let surfaced) = DaemonClient.classifyFastPathFailure(DaemonClientError.emptyResponse),
              let clientError = surfaced as? DaemonClientError,
              case .ambiguousExecution = clientError else {
            Issue.record("expected .surface(ambiguousExecution)")
            return
        }
        #expect(clientError.hint != nil)
    }

    @Test("malformed response is post-delivery → surface ambiguousExecution")
    func malformedResponseIsAmbiguous() {
        let err = DaemonClientError.malformedResponse(underlying: CocoaSentinel.boom)
        #expect(DaemonClient.requestReachedDaemon(err) == true)
        guard case .surface(let surfaced) = DaemonClient.classifyFastPathFailure(err),
              let clientError = surfaced as? DaemonClientError,
              case .ambiguousExecution = clientError else {
            Issue.record("expected .surface(ambiguousExecution)")
            return
        }
    }

    @Test("read-wait timeout is post-delivery → ambiguous")
    func readWaitTimeoutIsAmbiguous() {
        let err = DaemonClientError.transportFailure(op: "read-wait", errno: ETIMEDOUT, message: "timed out")
        #expect(DaemonClient.requestReachedDaemon(err) == true)
    }

    @Test("remote ok=false is surfaced verbatim, never ambiguous")
    func remoteSurfacedVerbatim() {
        let err = DaemonClientError.remote(message: "element not found", kind: .other, hint: "try --id")
        guard case .surface(let surfaced) = DaemonClient.classifyFastPathFailure(err),
              let clientError = surfaced as? DaemonClientError,
              case .remote = clientError else {
            Issue.record("expected .surface(remote)")
            return
        }
        #expect(clientError.hint == "try --id")
    }

    @Test("cancellation is surfaced verbatim")
    func cancellationSurfaced() {
        guard case .surface(let surfaced) = DaemonClient.classifyFastPathFailure(CancellationError()) else {
            Issue.record("expected .surface")
            return
        }
        #expect(surfaced is CancellationError)
    }

    private enum CocoaSentinel: Error { case boom }
}

// MARK: - Integration: a daemon that drops after receiving the request

@Suite("DaemonClient.invoke — ambiguous outcome without resend", .serialized)
struct DaemonClientAmbiguousIntegrationTests {

    private func makeTempDirectory() throws -> URL {
        let suffix = String(UUID().uuidString.prefix(6))
        let dir = URL(fileURLWithPath: "/tmp/sim-use-amb-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Bind the daemon's socket path and accept connections in a loop,
    /// reading each request line then closing WITHOUT a response —
    /// exactly what a daemon that crashed after receiving (and maybe
    /// executing) the command looks like on the wire. Returns the
    /// listening fd so the caller can close it to end the loop.
    private func startDroppingServer(at path: String) -> Int32 {
        let listenFd = try! DaemonSocket.listen(path: path)
        // DaemonSocket.listen sets O_NONBLOCK; restore blocking accept
        // for a simple loop.
        let flags = fcntl(listenFd, F_GETFL, 0)
        _ = fcntl(listenFd, F_SETFL, flags & ~O_NONBLOCK)
        Thread.detachNewThread {
            while true {
                let conn = Darwin.accept(listenFd, nil, nil)
                if conn < 0 { break }
                _ = DaemonSocket.readLine(fd: conn)
                Darwin.close(conn) // no response — drop the connection
            }
        }
        return listenFd
    }

    @Test("a mid-flight drop surfaces ambiguousExecution and does not respawn")
    func ambiguousDropNoResend() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let udid = "TEST-AMBIG-\(UUID().uuidString.prefix(8))"
        let paths = DaemonPaths(udid: udid, baseDirectory: tmp)
        try paths.ensureBaseDirectory()

        // Look alive: a bound socket + a pidfile naming a live process
        // (ourselves) makes filesystemLiveness report `probablyAlive`.
        let listenFd = startDroppingServer(at: paths.socketURL.path)
        defer { Darwin.close(listenFd) }
        try paths.writePidfile(getpid())

        do {
            _ = try await DaemonClient.invoke(
                command: "tap",
                args: [],
                udid: udid,
                baseDirectory: tmp
            )
            Issue.record("expected invoke to throw")
        } catch let error as DaemonClientError {
            guard case .ambiguousExecution = error else {
                Issue.record("expected .ambiguousExecution, got \(error)")
                return
            }
            #expect(error.hint != nil)
        }

        // No respawn: the pidfile still names our process. A fallthrough
        // to the spawn path would have removed it and started a real
        // daemon that overwrote it with a different pid.
        #expect(paths.readPidfile() == getpid())
    }
}
