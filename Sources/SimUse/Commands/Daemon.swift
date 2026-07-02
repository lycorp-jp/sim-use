// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Darwin
import Foundation
import AndroidBackend
import iOSSimBackend
import SimUseCore

/// Management CLI for the per-UDID auto-start daemon. The daemon itself
/// is hosted in-process by `sim-use daemon start`; `stop` and `status` are
/// client-side commands that talk to already-running daemons via the
/// shared wire protocol (`_stop` / `_ping`).
struct Daemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Manage the sim-use background daemon that amortises per-call init cost.",
        subcommands: [Start.self, Stop.self, Status.self]
    )

    // MARK: - start

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Run the sim-use daemon for a single simulator UDID in the foreground. The daemon listens on a per-UDID Unix socket and serves commands until idle timeout, SIGTERM/SIGINT, or an `_stop` request."
        )

        @OptionGroup var device: DeviceOptions

        @Option(
            name: .customLong("idle-timeout"),
            help: "Seconds with no requests before the daemon self-exits. Use 0 to disable (daemon runs forever). Default 600."
        )
        var idleTimeout: Double = 600

        mutating func validate() throws {
            try device.resolve()
            guard idleTimeout >= 0 else {
                throw ValidationError("--idle-timeout must be non-negative.")
            }
        }

        @MainActor
        func run() async throws {
            // Wire SimUse's ArgumentParser as the daemon's command parser
            // so DaemonDispatch can route requests without owning a
            // back-reference to the top-level command tree. Must happen
            // before the server starts accepting connections.
            DaemonDispatch.commandParser = { args in
                try SimUse.parseAsRoot(args)
            }
            // Register the iOS-specific cleanup that fires when an iOS
            // verb raises `staleSimulator`. The daemon module lives in
            // SimUseCore and stays platform-neutral; the actual HID
            // teardown lives here in iOSSimBackend. Android-only daemons
            // never raise `staleSimulator` so this hook is a no-op for
            // them — it's still installed to keep the code path uniform.
            DaemonDispatch.platformStaleCleanup = { udid in
                HIDInteractor.clearHIDConnection(for: udid)
            }
            // Wire the platform-appropriate live-app probe so the daemon
            // can detect a target process disappearing between commands
            // (issue #81). The daemon serves a single device, so the
            // probe is bound to this UDID/serial for its lifetime.
            let deviceId = device.resolved
            if PlatformRouter.looksLikeAndroid(deviceId) {
                // `livenessSnapshot` caches the rarely-changing third-party
                // package allowlist, so each command costs one `adb shell`
                // (the fresh `ps`), not two (issue #81 perf follow-up).
                DaemonDispatch.livenessProbe = { AndroidProcessLister.livenessSnapshot(serial: deviceId) }
            } else {
                DaemonDispatch.livenessProbe = { BundleIdentifierResolver.appSnapshot(udid: deviceId) }
            }
            let effectiveTimeout: TimeInterval = idleTimeout == 0 ? .infinity : idleTimeout
            let server = DaemonServer(udid: device.resolved, idleTimeout: effectiveTimeout)
            try await server.run()
        }
    }

    // MARK: - stop

    struct Stop: SimUseExecutableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop a running sim-use daemon by UDID, or every daemon for the current user via --all. Issues a cooperative `_stop` first, then falls back to SIGTERM if the process does not exit within --timeout."
        )

        @Option(name: .customLong("device"), help: "Stop only the daemon serving this device id (iOS Simulator UDID or Android adb serial).")
        var deviceArg: String?

        @Option(
            name: .customLong("udid"),
            help: ArgumentHelp(
                "Deprecated alias for --device. Still accepted; may be removed in a future release.",
                visibility: .default
            )
        )
        var udidArg: String?

        /// Resolved target — populated by `validate()`. Empty until then.
        var simulatorUDID: String?

        @Flag(name: .customLong("all"), help: "Stop every sim-use daemon running for the current user.")
        var all: Bool = false

        @Option(
            name: .customLong("timeout"),
            help: "Seconds to wait for each stop step (graceful then SIGTERM) before declaring the daemon unresponsive. Default 2."
        )
        var timeoutSeconds: Double = 2

        @Flag(name: .customLong("json"), help: "Emit results as a compact JSON envelope instead of human-readable text.")
        var jsonOutput: Bool = false

        struct StopEntry: Codable {
            let udid: String
            let pid: Int32
            /// "stop" | "stop+sigterm" | "sigterm" | "none"
            let method: String
            /// True once the pid is no longer reachable.
            let stopped: Bool
            /// Present when a per-daemon step failed but we still continued.
            let error: String?

            /// New cross-platform synonym for `udid`. Drop the `udid`
            /// key in Phase 2 once all consumers have migrated.
            private enum CodingKeys: String, CodingKey {
                case udid, deviceId, pid, method, stopped, error
            }

            init(udid: String, pid: Int32, method: String, stopped: Bool, error: String?) {
                self.udid = udid
                self.pid = pid
                self.method = method
                self.stopped = stopped
                self.error = error
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.udid = try c.decodeIfPresent(String.self, forKey: .deviceId)
                    ?? c.decode(String.self, forKey: .udid)
                self.pid = try c.decode(Int32.self, forKey: .pid)
                self.method = try c.decode(String.self, forKey: .method)
                self.stopped = try c.decode(Bool.self, forKey: .stopped)
                self.error = try c.decodeIfPresent(String.self, forKey: .error)
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(udid, forKey: .udid)
                try c.encode(udid, forKey: .deviceId)
                try c.encode(pid, forKey: .pid)
                try c.encode(method, forKey: .method)
                try c.encode(stopped, forKey: .stopped)
                try c.encodeIfPresent(error, forKey: .error)
            }
        }

        struct ExecutionResult: Codable {
            let entries: [StopEntry]
        }

        mutating func validate() throws {
            simulatorUDID = try DeviceOptions.selectExplicit(device: deviceArg, udid: udidArg)
            if (simulatorUDID == nil) == (!all) {
                throw ValidationError("Specify either --device <id> or --all (not both, not neither).")
            }
            guard timeoutSeconds >= 0 else {
                throw ValidationError("--timeout must be non-negative.")
            }
        }

        func execute() async throws -> ExecutionResult {
            let targets = try resolveTargets()
            var entries: [StopEntry] = []
            for target in targets {
                entries.append(await stopOne(target))
            }
            return ExecutionResult(entries: entries)
        }

        func format(_ result: ExecutionResult) -> CommandOutput {
            if result.entries.isEmpty {
                if let target = simulatorUDID {
                    return .line("No sim-use daemon running for device=\(target).")
                }
                return .line("No sim-use daemon running.")
            }
            let lines: [String] = result.entries.map { entry in
                var parts = [
                    "udid=\(entry.udid)",
                    "pid=\(entry.pid)",
                    "method=\(entry.method)",
                    "stopped=\(entry.stopped)"
                ]
                if let error = entry.error {
                    parts.append("error=\"\(error)\"")
                }
                return parts.joined(separator: " ")
            }
            return .lines(lines)
        }

        // Discover which daemons this invocation should target. A single
        // `--udid` with no live daemon yields an empty list so both the
        // CLI and `--json` path produce a "nothing to do" outcome rather
        // than an error; scripts wrapping this stay zero-exit.
        //
        // Throws on a base directory that fails the security gate: the
        // pids found here get SIGTERMed on the fallback path, so a
        // pre-planted tree must be an error, never a target list.
        private func resolveTargets() throws -> [DaemonPaths.DiscoveredDaemon] {
            if all {
                return try DaemonPaths.enumerateLiveDaemons()
            }
            guard let target = simulatorUDID else { return [] }
            let paths = DaemonPaths(udid: target)
            try DaemonPaths.validateBaseDirectory(at: paths.baseDirectory)
            if case .probablyAlive(let pid) = paths.filesystemLiveness() {
                return [DaemonPaths.DiscoveredDaemon(udid: target, pid: pid, paths: paths)]
            }
            return []
        }

        private func stopOne(_ target: DaemonPaths.DiscoveredDaemon) async -> StopEntry {
            let pid = target.pid
            let paths = target.paths
            var method = "none"
            var lastError: String?

            // 1. Cooperative _stop — daemon replies then initiates shutdown.
            //    Bounded by --timeout so a hung daemon cannot wedge us
            //    before we try the SIGTERM fallback below.
            var gracefulAccepted = false
            do {
                _ = try DaemonClient.sendToExistingDaemon(
                    socketPath: paths.socketURL.path,
                    command: DaemonProtocol.ManagementCommand.stop.rawValue,
                    readTimeout: timeoutSeconds
                )
                gracefulAccepted = true
                method = "stop"
            } catch {
                lastError = String(describing: error)
            }

            // 2. Poll for the pid to actually disappear.
            var exited = await awaitExit(pid: pid)

            // 3. SIGTERM fallback if graceful failed or didn't take effect.
            if !exited {
                let rc = Darwin.kill(pid, SIGTERM)
                if rc == 0 {
                    method = gracefulAccepted ? "stop+sigterm" : "sigterm"
                } else if lastError == nil {
                    lastError = "SIGTERM failed: \(String(cString: strerror(errno)))"
                }
                exited = await awaitExit(pid: pid)
            }

            // 4. Clean up stale socket/pidfile on confirmed exit.
            if exited {
                paths.removeSocket()
                paths.removePidfile()
            }

            return StopEntry(
                udid: target.udid,
                pid: pid,
                method: method,
                stopped: exited,
                error: exited ? nil : lastError
            )
        }

        private func awaitExit(pid: pid_t) async -> Bool {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline {
                if !DaemonPaths.isProcessAlive(pid: pid) { return true }
                try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
            }
            return !DaemonPaths.isProcessAlive(pid: pid)
        }
    }

    // MARK: - status

    struct Status: SimUseExecutableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "List running sim-use daemons for the current user with pid, uptime, and version."
        )

        @Flag(name: .customLong("json"), help: "Emit results as a compact JSON envelope instead of human-readable text.")
        var jsonOutput: Bool = false

        struct StatusEntry: Codable {
            let udid: String
            let pid: Int32
            let uptimeSeconds: Double
            let simUseVersion: String
            let protocolVersion: Int
            let socketPath: String
            let logPath: String
            /// True if `_ping` succeeded. False rows carry `error` instead.
            let reachable: Bool
            let error: String?

            /// Transitional dual-key for the device identifier. Drop the
            /// `udid` key in Phase 2 once consumers have migrated.
            private enum CodingKeys: String, CodingKey {
                case udid, deviceId, pid, uptimeSeconds, simUseVersion, protocolVersion,
                     socketPath, logPath, reachable, error
            }

            init(
                udid: String,
                pid: Int32,
                uptimeSeconds: Double,
                simUseVersion: String,
                protocolVersion: Int,
                socketPath: String,
                logPath: String,
                reachable: Bool,
                error: String?
            ) {
                self.udid = udid
                self.pid = pid
                self.uptimeSeconds = uptimeSeconds
                self.simUseVersion = simUseVersion
                self.protocolVersion = protocolVersion
                self.socketPath = socketPath
                self.logPath = logPath
                self.reachable = reachable
                self.error = error
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.udid = try c.decodeIfPresent(String.self, forKey: .deviceId)
                    ?? c.decode(String.self, forKey: .udid)
                self.pid = try c.decode(Int32.self, forKey: .pid)
                self.uptimeSeconds = try c.decode(Double.self, forKey: .uptimeSeconds)
                self.simUseVersion = try c.decode(String.self, forKey: .simUseVersion)
                self.protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
                self.socketPath = try c.decode(String.self, forKey: .socketPath)
                self.logPath = try c.decode(String.self, forKey: .logPath)
                self.reachable = try c.decode(Bool.self, forKey: .reachable)
                self.error = try c.decodeIfPresent(String.self, forKey: .error)
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(udid, forKey: .udid)
                try c.encode(udid, forKey: .deviceId)
                try c.encode(pid, forKey: .pid)
                try c.encode(uptimeSeconds, forKey: .uptimeSeconds)
                try c.encode(simUseVersion, forKey: .simUseVersion)
                try c.encode(protocolVersion, forKey: .protocolVersion)
                try c.encode(socketPath, forKey: .socketPath)
                try c.encode(logPath, forKey: .logPath)
                try c.encode(reachable, forKey: .reachable)
                try c.encodeIfPresent(error, forKey: .error)
            }
        }

        struct ExecutionResult: Codable {
            let daemons: [StatusEntry]
        }

        func execute() async throws -> ExecutionResult {
            let discovered = try DaemonPaths.enumerateLiveDaemons()
            var entries: [StatusEntry] = []
            for daemon in discovered {
                entries.append(pingOne(daemon))
            }
            return ExecutionResult(daemons: entries)
        }

        func format(_ result: ExecutionResult) -> CommandOutput {
            if result.daemons.isEmpty {
                return .line("No sim-use daemon running.")
            }
            let lines: [String] = result.daemons.map { entry in
                if entry.reachable {
                    return "udid=\(entry.udid) pid=\(entry.pid) uptime=\(formatUptime(entry.uptimeSeconds)) version=\(entry.simUseVersion)"
                }
                let errorSuffix = entry.error.map { " error=\"\($0)\"" } ?? ""
                return "udid=\(entry.udid) pid=\(entry.pid) unreachable\(errorSuffix)"
            }
            return .lines(lines)
        }

        private func pingOne(_ daemon: DaemonPaths.DiscoveredDaemon) -> StatusEntry {
            do {
                let responseData = try DaemonClient.sendToExistingDaemon(
                    socketPath: daemon.paths.socketURL.path,
                    command: DaemonProtocol.ManagementCommand.ping.rawValue,
                    readTimeout: 2.0
                )
                let ping = try JSONDecoder()
                    .decode(DaemonClientSuccessPayload<DaemonPingData>.self, from: responseData)
                    .data
                return StatusEntry(
                    udid: daemon.udid,
                    pid: ping.pid,
                    uptimeSeconds: ping.uptimeSeconds,
                    simUseVersion: ping.simUseVersion,
                    protocolVersion: ping.protocolVersion,
                    socketPath: daemon.paths.socketURL.path,
                    logPath: daemon.paths.logfileURL.path,
                    reachable: true,
                    error: nil
                )
            } catch {
                return StatusEntry(
                    udid: daemon.udid,
                    pid: daemon.pid,
                    uptimeSeconds: 0,
                    simUseVersion: "",
                    protocolVersion: 0,
                    socketPath: daemon.paths.socketURL.path,
                    logPath: daemon.paths.logfileURL.path,
                    reachable: false,
                    error: String(describing: error)
                )
            }
        }

        private func formatUptime(_ seconds: Double) -> String {
            let total = Int(seconds.rounded())
            if total < 60 { return "\(total)s" }
            let minutes = total / 60
            let secondsPart = total % 60
            if minutes < 60 { return "\(minutes)m\(secondsPart)s" }
            let hours = minutes / 60
            let minutesPart = minutes % 60
            return "\(hours)h\(minutesPart)m"
        }
    }
}