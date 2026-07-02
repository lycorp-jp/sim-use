// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation

/// Long-running server hosted by `sim-use daemon start`. Owns a listening
/// Unix-domain socket, accepts one connection at a time, dispatches each
/// request through `DaemonDispatch`, and writes the response back on the
/// same connection before closing it.
///
/// Lifetime signals (any one triggers a clean shutdown):
///  * SIGTERM / SIGINT from the OS or operator
///  * `_stop` management command from a client
///  * idle timeout (configurable; default 600 s)
///
/// `@MainActor` here is iOS-driven — FBSimulatorControl requires the
/// main actor, so iOS verbs running through `DaemonDispatch.handle`
/// must reach it. Android verbs don't need MainActor pinning but
/// don't suffer from it either; one-at-a-time serialisation is a
/// fine fit for the per-UDID daemon shape regardless of platform.
/// Dispatch sources hop into a Task on the main actor before touching
/// instance state.
@MainActor
public final class DaemonServer {
    private let udid: String
    private let paths: DaemonPaths
    private let idleTimeout: TimeInterval
    private let simUseVersion: String
    private let startTime = Date()

    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var signalSources: [DispatchSourceSignal] = []
    private var idleTimer: DispatchSourceTimer?
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    private var isShuttingDown = false
    private var activeRequests = 0
    /// Tail of the request-handling chain. Each newly-accepted
    /// connection is appended to this chain so we process requests
    /// strictly one at a time, which is what FBSimulatorControl and
    /// the Objective-C bridge actually want — concurrent MainActor
    /// tasks interleave at `await` boundaries and cause the
    /// cross-request response shuffle we observed during first
    /// manual-nc testing.
    private var handleChain: Task<Void, Never>?

    public init(
        udid: String,
        idleTimeout: TimeInterval = 600,
        paths: DaemonPaths? = nil,
        simUseVersion: String? = nil
    ) {
        self.udid = udid
        self.paths = paths ?? DaemonPaths(udid: udid)
        self.idleTimeout = idleTimeout
        // VERSION is generated per-target by VersionPlugin and is
        // module-internal, so we can't reference it from a public default
        // arg. Resolve here instead; callers can override with the host
        // CLI's VERSION for an end-to-end matching stamp.
        self.simUseVersion = simUseVersion ?? VERSION
    }

    /// Boot the server and block until one of the shutdown conditions
    /// fires. Throws if the socket cannot be bound (usually because
    /// another daemon is already listening on the same UDID).
    public func run() async throws {
        // Set before any dispatch happens so recursively-spawned
        // commands running inside this process route straight through
        // execute() instead of looping back into DaemonClient.
        setenv("SIM_USE_IN_DAEMON", "1", 1)

        try paths.ensureBaseDirectory()
        try paths.writePidfile(getpid())
        listenFd = try DaemonSocket.listen(path: paths.socketURL.path)
        installAcceptSource()
        installSignalSources()
        installIdleTimer()
        logInfo("sim-use-daemon: listening on \(paths.socketURL.path) udid=\(udid) pid=\(getpid()) idle=\(idleTimeoutDescription)")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.shutdownContinuation = cont
        }

        cleanup()
    }

    // MARK: - Accept loop

    private func installAcceptSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFd, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.acceptReady()
            }
        }
        source.resume()
        acceptSource = source
    }

    private func acceptReady() {
        // Listener is non-blocking; drain the accept queue until EAGAIN.
        // A single DispatchSource firing may correspond to multiple
        // pending connections, and relying on repeated source firings
        // to pick them up one-by-one is racey: a stray fire against an
        // empty queue combined with a blocking accept would deadlock
        // the main actor (observed in sampling during describe-ui
        // hangs). Looping here turns that into a clean EAGAIN exit.
        while true {
            let connFd = Darwin.accept(listenFd, nil, nil)
            if connFd < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                if errno == EBADF || errno == EINVAL {
                    // Listener was closed during shutdown.
                    return
                }
                if errno == EINTR { continue }
                logInfo("sim-use-daemon: accept() errno=\(errno) \(String(cString: strerror(errno)))")
                return
            }

            // accept(2) on BSD/macOS inherits the listener's file
            // status flags — including the O_NONBLOCK we set on the
            // listening fd to keep the accept loop drain-safe. Our
            // readLine is strictly blocking-style (treats a short
            // read as EOF), so a non-blocking accepted fd races the
            // client's first write: read() fires first, returns
            // EAGAIN, readLine returns nil, we log "empty request"
            // and close the fd. The client's subsequent write then
            // gets EPIPE. Force the connected fd back to blocking
            // before handing it to the handler chain.
            let connFlags = fcntl(connFd, F_GETFL, 0)
            if connFlags >= 0 && (connFlags & O_NONBLOCK) != 0 {
                _ = fcntl(connFd, F_SETFL, connFlags & ~O_NONBLOCK)
            }

            // Raise the AF_UNIX send buffer. macOS defaults to ~8 KB,
            // which means a single Darwin.write() of a 17-30 KB
            // describe-ui response cannot fit and the kernel returns
            // EPIPE if the peer has not drained anything yet. 1 MB is
            // plenty for any ExecutionResult we expect to emit.
            var sndbuf: Int32 = 1 * 1024 * 1024
            _ = setsockopt(connFd, SOL_SOCKET, SO_SNDBUF, &sndbuf, socklen_t(MemoryLayout<Int32>.size))

            enqueueHandleConnection(connFd)
        }
    }

    /// Append a fresh connection handler onto the serial chain. The new
    /// task awaits the previous one's completion before running, so
    /// handlers execute one-at-a-time FIFO even though each is spawned
    /// eagerly off the accept event.
    private func enqueueHandleConnection(_ fd: Int32) {
        let previous = handleChain
        handleChain = Task { @MainActor [weak self] in
            if let previous {
                _ = await previous.value
            }
            guard let self else {
                Darwin.close(fd)
                return
            }
            await self.handleConnection(fd)
        }
    }

    private func handleConnection(_ fd: Int32) async {
        activeRequests += 1
        let connectionId = UUID().uuidString.prefix(8)
        logInfo("sim-use-daemon: accepted connection (conn=\(connectionId), active=\(activeRequests))")
        defer {
            Darwin.close(fd)
            activeRequests -= 1
            logInfo("sim-use-daemon: closed connection (conn=\(connectionId), active=\(activeRequests))")
        }
        resetIdleTimer()

        guard let line = DaemonSocket.readLine(fd: fd), !line.isEmpty else {
            logInfo("sim-use-daemon: empty request (conn=\(connectionId)), closing")
            return
        }
        logInfo("sim-use-daemon: received request (conn=\(connectionId), \(line.count) bytes)")

        let request: DaemonRequest
        do {
            request = try JSONDecoder().decode(DaemonRequest.self, from: line)
        } catch {
            let envelope = DaemonErrorResponse(error: "daemon: malformed JSON request: \(error.localizedDescription)", kind: .permanent)
            writeResponse(fd: fd, encodable: envelope)
            return
        }

        let snapshot = DaemonDispatch.Snapshot(
            pid: getpid(),
            startTime: startTime,
            udid: udid,
            simUseVersion: simUseVersion
        )
        logInfo("sim-use-daemon: dispatching cmd=\(request.cmd) (conn=\(connectionId))")
        let outcome = await DaemonDispatch.handle(request, snapshot: snapshot)

        var responseBuf = outcome.responseData
        responseBuf.append(0x0A)
        let writeResult = DaemonSocket.writeAll(fd: fd, data: responseBuf)
        if writeResult.ok {
            logInfo("sim-use-daemon: wrote response (conn=\(connectionId), bytes=\(responseBuf.count), ok=true)")
        } else {
            let errstr = String(cString: strerror(writeResult.lastErrno))
            logInfo("sim-use-daemon: wrote response FAILED (conn=\(connectionId), bytes=\(responseBuf.count), errno=\(writeResult.lastErrno) \(errstr))")
        }
        resetIdleTimer()

        if outcome.shouldStopDaemon {
            logInfo("sim-use-daemon: _stop acknowledged, initiating shutdown")
            triggerShutdown()
        }
    }

    private func writeResponse<T: Encodable>(fd: Int32, encodable: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(encodable) else { return }
        data.append(0x0A)
        _ = DaemonSocket.writeAll(fd: fd, data: data)
    }

    // MARK: - Signals

    private func installSignalSources() {
        // Default action for SIGTERM/SIGINT would terminate before our
        // dispatch source handlers run. Ignoring via signal() hands
        // delivery cleanly to the kqueue-backed dispatch source.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.logInfo("sim-use-daemon: received signal \(sig), stopping")
                    self?.triggerShutdown()
                }
            }
            source.resume()
            signalSources.append(source)
        }
        // A dead client must not take the daemon down via SIGPIPE on its
        // closed socket. Ignore so writeAll simply returns false.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Idle timer

    private func installIdleTimer() {
        guard idleTimeout.isFinite, idleTimeout > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + idleTimeout, repeating: .never)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // "Idle" means no request in flight. The timer counts from
                // the last reset (request start / response end), so a
                // single request that runs longer than idleTimeout — e.g.
                // `tap --wait-timeout 700` or a long `batch` — would
                // otherwise trip it mid-execution and tear the daemon down
                // while the command is still running. Reschedule instead;
                // the reset after the response goes out starts the real
                // idle countdown.
                guard self.activeRequests == 0 else {
                    self.resetIdleTimer()
                    return
                }
                self.logInfo("sim-use-daemon: idle timeout reached, stopping")
                self.triggerShutdown()
            }
        }
        timer.resume()
        idleTimer = timer
    }

    private func resetIdleTimer() {
        idleTimer?.schedule(deadline: .now() + idleTimeout, repeating: .never)
    }

    // MARK: - Shutdown

    private func triggerShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        shutdownContinuation?.resume()
        shutdownContinuation = nil
    }

    private func cleanup() {
        acceptSource?.cancel()
        idleTimer?.cancel()
        for s in signalSources { s.cancel() }
        signalSources.removeAll()
        if listenFd >= 0 {
            Darwin.close(listenFd)
            listenFd = -1
        }
        // Only remove the socket/pidfile while this process still owns
        // them. A successor daemon may have taken the paths over —
        // `listen()` unlinks + rebinds the socket and the pidfile gets
        // overwritten — while this instance idled toward shutdown. An
        // orphan wiping the live daemon's files makes the successor
        // invisible to clients, which then spawn yet another daemon
        // and chain more orphans. Ownership is only honoured while the
        // owner is still alive: a dead owner's files are stale garbage
        // (and its recycled pid could fake a live daemon later), so
        // they are cleaned like the missing/unparseable-pidfile case.
        let owner = paths.readPidfile()
        if let owner, owner != getpid(), DaemonPaths.isProcessAlive(pid: owner) {
            logInfo("sim-use-daemon: cleanup complete (paths taken over by live pid \(owner); files left in place)")
            return
        }
        paths.removeSocket()
        paths.removePidfile()
        logInfo("sim-use-daemon: cleanup complete")
    }

    // MARK: - Logging

    private func logInfo(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private var idleTimeoutDescription: String {
        guard idleTimeout.isFinite, idleTimeout > 0 else { return "disabled" }
        return "\(Int(idleTimeout))s"
    }
}