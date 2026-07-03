// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Client-side transport for the per-UDID daemon. Encapsulates:
///
/// * connect to the existing socket if a daemon is alive
/// * fork-exec a detached `sim-use daemon start` if one is not
/// * wait for the freshly-spawned daemon's socket to become ready
/// * retry once on `transient_booting` errors (post-`simctl boot`
///   accessibility-readiness gap)
///
/// Returns the raw response envelope bytes so callers can decode into
/// their own typed `ExecutionResult` via the shared response shape.
public enum DaemonClient {
    /// Top-level entry: send a command to the right daemon and return
    /// the response line (without trailing newline).
    ///
    /// `baseDirectory` overrides the default `/tmp/sim-use-<uid>/` tree;
    /// production callers leave it nil, tests pass an isolated directory.
    /// `transientRetryDelay` is the pause before the single
    /// `transient_booting` re-send (see `sendClassifiedRequest`).
    public static func invoke(
        command: String,
        args: [String],
        udid: String,
        baseDirectory: URL? = nil,
        transientRetryDelay: TimeInterval = 1.0
    ) async throws -> Data {
        // Ignore SIGPIPE for the remainder of the process. Without it,
        // any write() on a socket whose peer has closed its read side
        // terminates the CLI with signal 13 before our EPIPE-handling
        // code in writeAll gets to run. Cheap and idempotent.
        signal(SIGPIPE, SIG_IGN)

        let paths = DaemonPaths(udid: udid, baseDirectory: baseDirectory)
        try paths.ensureBaseDirectory()

        var liveness = paths.filesystemLiveness()
        trace("invoke cmd=\(command) liveness=\(liveness)")

        // Version gate: if a daemon is live but was spawned from a
        // different binary (git checkout + rebuild mid-session, stale
        // dev iteration, etc.), restart it now so the client never
        // dispatches real work to a server that no longer reflects
        // the CLI's code. Returns early when the daemon is either
        // absent, already compatible, or the probe itself was
        // inconclusive — in all those cases the existing fast/slow
        // paths handle the rest.
        if case .probablyAlive = liveness,
           await ensureCompatibleDaemon(paths: paths, currentVersion: VERSION) {
            liveness = paths.filesystemLiveness()
            trace("post-gate liveness=\(liveness)")
        }

        // Fast path: a daemon already appears to be live.
        if case .probablyAlive = liveness {
            do {
                return try await sendClassifiedRequest(
                    command: command,
                    args: args,
                    paths: paths,
                    transientRetryDelay: transientRetryDelay
                )
            } catch {
                switch classifyFastPathFailure(error) {
                case .surface(let surfaced):
                    // Cancellation, a `remote` ok=false answer, or a
                    // post-write ambiguity — surface as-is. Crucially we
                    // do NOT respawn+resend on ambiguity: the daemon may
                    // have executed the command before dropping the
                    // response, so a blind resend could run a
                    // side-effecting verb twice. Leave the files for the
                    // next call's liveness probe to reconcile.
                    throw surfaced
                case .respawn:
                    // The command provably never reached the daemon
                    // (connect/write failed) — this is the stale-daemon
                    // case. Clean up and fall through to respawn+resend.
                    trace("fast-path pre-delivery failure: \(error). Removing stale files.")
                    paths.removeSocket()
                    paths.removePidfile()
                }
            }
        }

        // No live daemon: spawn a detached one and wait for it.
        trace("spawning fresh daemon")
        try spawnDaemon(udid: udid, paths: paths)
        try await waitForSocket(paths: paths, timeout: 5.0)
        trace("socket ready after spawn")

        do {
            return try await sendClassifiedRequest(
                command: command,
                args: args,
                paths: paths,
                transientRetryDelay: transientRetryDelay
            )
        } catch {
            // The fresh daemon can also drop the connection after
            // receiving the request. Re-tag that post-write ambiguity so
            // the agent hears "unknown outcome" rather than a bare
            // transport error; there is no second respawn to attempt.
            throw surfacedError(error)
        }
    }

    /// What the fast-path catch should do with a `sendClassifiedRequest`
    /// failure.
    enum FastPathFailureDecision {
        /// Surface this error to the caller unchanged — no respawn.
        case surface(Error)
        /// The request provably never reached the daemon; clean up the
        /// stale files and respawn a fresh one.
        case respawn
    }

    /// Decide the fast-path response to a failure. Extracted for unit
    /// testing — the daemon-vs-inline resend policy is the load-bearing
    /// at-most-once guarantee and must not silently regress.
    static func classifyFastPathFailure(_ error: Error) -> FastPathFailureDecision {
        // Cancellation and `remote` answers are always surfaced as-is.
        if error is CancellationError {
            return .surface(error)
        }
        if let clientError = error as? DaemonClientError, case .remote = clientError {
            return .surface(clientError)
        }
        // Post-write ambiguity: the bytes reached the daemon, so the
        // command may have executed. Surface a typed ambiguity error
        // instead of respawning.
        if requestReachedDaemon(error) {
            return .surface(DaemonClientError.ambiguousExecution(underlying: error))
        }
        // Everything else is a pre-delivery transport failure (connect or
        // write) — the command never ran, so respawning is safe.
        return .respawn
    }

    /// Map a spawn-path failure for surfacing: same rules as the fast
    /// path minus the respawn option (there is no second daemon to spawn).
    static func surfacedError(_ error: Error) -> Error {
        switch classifyFastPathFailure(error) {
        case .surface(let surfaced):
            return surfaced
        case .respawn:
            // A connect/write failure against the daemon we just spawned
            // is a genuine transport problem, not an ambiguity — surface
            // it verbatim.
            return error
        }
    }

    /// True when the failure happened AFTER the request bytes were handed
    /// to the daemon — i.e. the command may already have executed.
    /// `connect` failures (`DaemonSocketError`) and `write` failures mean
    /// the request never landed, so the command provably did not run.
    /// Empty / malformed / post-write read failures are ambiguous.
    static func requestReachedDaemon(_ error: Error) -> Bool {
        switch error {
        case is DaemonSocketError:
            return false
        case let clientError as DaemonClientError:
            switch clientError {
            case .transportFailure(let op, _, _):
                // `write` fails before delivery; `read`/`read-wait` fail
                // after the request is already on the wire.
                return op != "write"
            case .emptyResponse, .malformedResponse:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    /// Send + classify one business request, retrying exactly once when
    /// the daemon reports `transient_booting` (the post-`simctl boot`
    /// accessibility-readiness gap). The retry targets the SAME daemon:
    /// booting is the simulator's condition, not the server's, so a
    /// respawn would only add latency. Any other failure — including a
    /// second `transient_booting` — propagates to the caller.
    private static func sendClassifiedRequest(
        command: String,
        args: [String],
        paths: DaemonPaths,
        transientRetryDelay: TimeInterval
    ) async throws -> Data {
        do {
            let response = try sendRequest(command: command, args: args, to: paths.socketURL.path)
            trace("sendRequest OK \(response.count) bytes, classifying")
            return try classify(response: response)
        } catch let error as DaemonClientError {
            guard case .remote(_, .transientBooting, _) = error else { throw error }
            trace("transient_booting; retrying once after \(transientRetryDelay)s")
            // `transientRetryDelay` is public API: guard the nanosecond
            // conversion against non-finite/overflowing values (skip the
            // pause, retry immediately) instead of trapping. The cap only
            // bounds the conversion; sane callers stay well below it.
            if transientRetryDelay.isFinite, transientRetryDelay > 0 {
                let cappedSeconds = min(transientRetryDelay, 60)
                try await Task.sleep(nanoseconds: UInt64(cappedSeconds * 1_000_000_000))
            }
            try Task.checkCancellation()
            let response = try sendRequest(command: command, args: args, to: paths.socketURL.path)
            trace("retry sendRequest OK \(response.count) bytes, classifying")
            return try classify(response: response)
        }
    }

    /// Probe a live daemon with `_ping`, compare its `simUseVersion`
    /// against `currentVersion`, and — on mismatch — shut it down so
    /// `invoke`'s spawn path rebuilds a fresh one from the current
    /// binary.
    ///
    /// Returns `true` when a restart was performed (caller should
    /// re-read liveness). `false` means no action was needed: ping
    /// succeeded with a matching version, or the probe itself failed
    /// hard enough that the existing transport-error handling should
    /// take over.
    ///
    /// Opt-out: `SIM_USE_DAEMON_VERSION_CHECK=0` in the environment
    /// disables the gate entirely, falling back to pre-gate behaviour
    /// for emergency use.
    public static func ensureCompatibleDaemon(
        paths: DaemonPaths,
        currentVersion: String
    ) async -> Bool {
        if ProcessInfo.processInfo.environment["SIM_USE_DAEMON_VERSION_CHECK"] == "0" {
            return false
        }
        let daemonVersion: String
        do {
            let responseData = try sendToExistingDaemon(
                socketPath: paths.socketURL.path,
                command: DaemonProtocol.ManagementCommand.ping.rawValue,
                readTimeout: 2.0
            )
            let ping = try JSONDecoder()
                .decode(DaemonClientSuccessPayload<DaemonPingData>.self, from: responseData)
                .data
            daemonVersion = ping.simUseVersion
        } catch {
            trace("version probe failed: \(error); letting fast-path take over")
            return false
        }

        guard shouldRestartForVersion(daemon: daemonVersion, current: currentVersion) else {
            return false
        }

        trace("version mismatch daemon=\(daemonVersion) cli=\(currentVersion); restarting")
        await stopDaemon(paths: paths, timeout: 2.0)
        return true
    }

    /// Pure comparator: decides whether an extant daemon should be
    /// torn down for a fresh one. Mirrors exact-string equality for
    /// now; empty or whitespace-only strings on either side are
    /// treated as "unknown" and do NOT trigger a restart so we don't
    /// crash-loop on broken `VersionPlugin` output.
    public static func shouldRestartForVersion(daemon: String, current: String) -> Bool {
        let lhs = daemon.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if lhs.isEmpty || rhs.isEmpty { return false }
        return lhs != rhs
    }

    /// Cooperative stop + SIGTERM fallback + filesystem cleanup. Used
    /// by the version gate to bring a mismatched daemon down so the
    /// spawn path can bring up a fresh one. Best-effort: transport /
    /// permission errors are swallowed so `invoke` always gets a
    /// chance to re-spawn.
    public static func stopDaemon(paths: DaemonPaths, timeout: TimeInterval) async {
        _ = try? sendToExistingDaemon(
            socketPath: paths.socketURL.path,
            command: DaemonProtocol.ManagementCommand.stop.rawValue,
            readTimeout: timeout
        )
        // A pidfile naming our own process is never a daemon we can
        // wait out or SIGTERM: a stale pidfile can hold a recycled pid,
        // and in-process daemons (tests) write getpid(). Signalling
        // ourselves fans out through every live DaemonServer's SIGTERM
        // dispatch source and tears down unrelated daemons.
        if let pid = paths.readPidfile(), pid != getpid() {
            await awaitExit(pid: pid, timeout: timeout)
            if DaemonPaths.isProcessAlive(pid: pid) {
                _ = Darwin.kill(pid, SIGTERM)
                await awaitExit(pid: pid, timeout: timeout)
            }
        }
        paths.removeSocket()
        paths.removePidfile()
    }

    private static func awaitExit(pid: pid_t, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !DaemonPaths.isProcessAlive(pid: pid) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Send a request to an **existing** daemon socket without probing
    /// liveness or auto-spawning on failure. Intended for management
    /// subcommands (`daemon stop`, `daemon status`) which operate on
    /// daemons the caller has already enumerated via
    /// `DaemonPaths.enumerateLiveDaemons()`. Errors bubble up verbatim
    /// so the caller can present per-daemon outcomes.
    ///
    /// `readTimeout`, when non-nil, caps how long we block waiting for
    /// the first response byte. Business-command `invoke` leaves it nil
    /// (describe-ui etc. can legitimately take seconds); management
    /// callers pass a small value so a hung daemon cannot wedge the CLI.
    public static func sendToExistingDaemon(
        socketPath: String,
        command: String,
        args: [String] = [],
        readTimeout: TimeInterval? = nil
    ) throws -> Data {
        signal(SIGPIPE, SIG_IGN)
        let response = try sendRequest(
            command: command,
            args: args,
            to: socketPath,
            readTimeout: readTimeout
        )
        return try classify(response: response)
    }

    private static func trace(_ msg: String) {
        guard ProcessInfo.processInfo.environment["SIM_USE_DAEMON_CLIENT_TRACE"] == "1" else { return }
        FileHandle.standardError.write(Data("[client-trace] \(msg)\n".utf8))
    }

    // MARK: - Wire

    private static func sendRequest(
        command: String,
        args: [String],
        to socketPath: String,
        readTimeout: TimeInterval? = nil
    ) throws -> Data {
        let fd = try DaemonSocket.connect(path: socketPath)
        defer { Darwin.close(fd) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var requestData = try encoder.encode(DaemonRequest(cmd: command, args: args))
        requestData.append(0x0A)

        let writeResult = DaemonSocket.writeAll(fd: fd, data: requestData)
        guard writeResult.ok else {
            throw DaemonClientError.transportFailure(
                op: "write",
                errno: writeResult.lastErrno,
                message: String(cString: strerror(writeResult.lastErrno))
            )
        }

        // Optional: bail out early if the daemon stops talking back within
        // the caller's budget. We poll for POLLIN once before the blocking
        // readLine — the subsequent read(2) calls drain quickly because
        // data is already on the wire. Only used by management callers;
        // business invoke leaves this nil.
        if let readTimeout {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let timeoutMs = Int32(max(1, Int(readTimeout * 1000)))
            let pollResult = poll(&pfd, 1, timeoutMs)
            if pollResult <= 0 {
                let err = pollResult == 0 ? ETIMEDOUT : errno
                throw DaemonClientError.transportFailure(
                    op: "read-wait",
                    errno: err,
                    message: String(cString: strerror(err))
                )
            }
        }

        guard let responseLine = DaemonSocket.readLine(fd: fd), !responseLine.isEmpty else {
            throw DaemonClientError.emptyResponse
        }
        return responseLine
    }

    /// Convert an error envelope into a typed Swift error; let success
    /// envelopes pass through untouched for the caller to decode its
    /// own `ExecutionResult`.
    private static func classify(response: Data) throws -> Data {
        struct Peek: Decodable {
            public let ok: Bool
            public let error: String?
            public let kind: DaemonErrorKind?
            public let hint: String?
        }
        let peek: Peek
        do {
            peek = try JSONDecoder().decode(Peek.self, from: response)
        } catch {
            throw DaemonClientError.malformedResponse(underlying: error)
        }
        if peek.ok { return response }
        throw DaemonClientError.remote(
            message: peek.error ?? "daemon returned ok=false with no error",
            kind: peek.kind ?? .other,
            hint: peek.hint
        )
    }

    // MARK: - Spawn

    private static func spawnDaemon(udid: String, paths: DaemonPaths) throws {
        guard let executablePath = Bundle.main.executablePath else {
            throw DaemonClientError.cannotLocateExecutable
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = ["daemon", "start", "--udid", udid]
        task.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        // Daemon stderr (incl. SimUseLogger output + SIM_USE_PERF timings) goes
        // into a per-UDID log file so users can inspect post-mortem.
        if !FileManager.default.fileExists(atPath: paths.logfileURL.path) {
            FileManager.default.createFile(atPath: paths.logfileURL.path, contents: nil)
        }
        if let logHandle = try? FileHandle(forWritingTo: paths.logfileURL) {
            logHandle.seekToEndOfFile()
            task.standardOutput = logHandle
            task.standardError = logHandle
        }

        do {
            try task.run()
        } catch {
            throw DaemonClientError.spawnFailed(underlying: error)
        }
        // Deliberately do NOT call waitUntilExit — the daemon runs
        // detached for the lifetime of this process chain and beyond.
    }

    /// Poll until the socket file exists, or timeout. Intentionally
    /// does *not* open a probe connection: a connect+close probe leaves
    /// an empty connection queued on the daemon which serialises behind
    /// the real request and sometimes races the read/write timing on
    /// the first real send. File existence + pidfile is enough to
    /// prove the server has finished bind+listen; if it hasn't, the
    /// subsequent sendRequest's connect will itself fail and trigger
    /// the caller's regular error path.
    private static func waitForSocket(paths: DaemonPaths, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: paths.socketURL.path),
               paths.readPidfile() != nil {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        }
        throw DaemonClientError.spawnTimedOut(socket: paths.socketURL.path, waited: timeout)
    }
}

public enum DaemonClientError: Error, CustomStringConvertible, HintProviding {
    case cannotLocateExecutable
    case spawnFailed(underlying: Error)
    case spawnTimedOut(socket: String, waited: TimeInterval)
    case transportFailure(op: String, errno: Int32, message: String)
    case emptyResponse
    case malformedResponse(underlying: Error)
    case remote(message: String, kind: DaemonErrorKind, hint: String?)
    /// The request was delivered to the daemon, but no valid response
    /// came back (the connection dropped or the reply was unparseable).
    /// The command may or may not have executed, so the client did not
    /// resend it — the caller decides.
    case ambiguousExecution(underlying: Error)

    public var description: String {
        switch self {
        case .cannotLocateExecutable:
            return "Could not locate the sim-use executable to spawn the daemon."
        case .spawnFailed(let err):
            return "Failed to start sim-use daemon: \(err.localizedDescription)"
        case .spawnTimedOut(let socket, let waited):
            return "Timed out after \(waited)s waiting for daemon socket at \(socket)."
        case .transportFailure(let op, let errno, let message):
            return "Daemon \(op) failed (errno=\(errno)): \(message)"
        case .emptyResponse:
            return "Daemon closed the connection without sending a response."
        case .malformedResponse(let err):
            return "Daemon response could not be parsed: \(err.localizedDescription)"
        case .remote(let message, _, _):
            return message
        case .ambiguousExecution(let err):
            return "The command reached the sim-use daemon but no valid response came back "
                + "(\(err.localizedDescription)). It may or may not have executed; "
                + "sim-use did not resend it to avoid running a side-effecting command twice."
        }
    }

    public var kind: DaemonErrorKind {
        if case .remote(_, let kind, _) = self { return kind }
        return .other
    }

    public var hint: String? {
        switch self {
        case .remote(_, _, let hint):
            return hint
        case .ambiguousExecution:
            return "Re-observe the screen with `sim-use ui` to check whether the command took "
                + "effect, then retry only if it did not. sim-use avoids automatic retries here "
                + "so a tap/type/swipe is never applied twice."
        default:
            return nil
        }
    }
}

extension DaemonClientError: LocalizedError {
    public var errorDescription: String? { description }
}