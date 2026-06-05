// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Thin subprocess wrapper around the `adb` CLI. Stays a value-type
/// configuration container so callers can spin up multiple `Adb`
/// instances per-test with custom binary paths / timeouts. No global
/// state.
///
/// Errors map to `BridgeError` so AndroidBackend callers see a uniform
/// failure surface.
public struct Adb: Sendable {
    public let binaryPath: String
    public let defaultTimeout: TimeInterval

    public init(binaryPath: String? = nil, defaultTimeout: TimeInterval = 30) {
        if let binaryPath {
            self.binaryPath = binaryPath
        } else {
            self.binaryPath = Self.discover()
        }
        self.defaultTimeout = defaultTimeout
    }

    /// Resolve an `adb` binary on this host. Priority:
    ///   1. `$SIM_USE_ADB` env override (absolute path).
    ///   2. `$ANDROID_SDK_ROOT/platform-tools/adb`.
    ///   3. `$ANDROID_HOME/platform-tools/adb` (legacy).
    ///   4. `$HOME/Library/Android/sdk/platform-tools/adb` (macOS default).
    ///   5. `/opt/homebrew/bin/adb` (brew android-platform-tools cask).
    ///   6. `/usr/local/bin/adb` (Intel brew / manual install).
    ///   7. Final fallback: `adb` on PATH.
    ///
    /// We never throw here — `run()` surfaces `BridgeError.adbMissing` if
    /// the chosen path is non-executable.
    public static func discover(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = env["SIM_USE_ADB"], !override.isEmpty {
            return override
        }
        let fm = FileManager.default
        var candidates: [String] = []
        if let root = env["ANDROID_SDK_ROOT"], !root.isEmpty {
            candidates.append("\(root)/platform-tools/adb")
        }
        if let home = env["ANDROID_HOME"], !home.isEmpty {
            candidates.append("\(home)/platform-tools/adb")
        }
        if let user = env["HOME"], !user.isEmpty {
            candidates.append("\(user)/Library/Android/sdk/platform-tools/adb")
        }
        candidates.append("/opt/homebrew/bin/adb")
        candidates.append("/usr/local/bin/adb")
        for candidate in candidates {
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "adb"
    }

    // MARK: - High-level wrappers

    /// `adb devices -l`. Returns one row per attached device. Filters
    /// out the header line and unauthorized / offline entries.
    public func devices() throws -> [Device] {
        let output = try run(args: ["devices", "-l"])
        return Self.parseDevices(output.stdout)
    }

    public struct Device: Equatable, Sendable {
        public let serial: String
        public let state: String       // e.g. "device", "offline", "unauthorized"
        /// `model:Pixel_5_API_34`, `product:sdk_gphone64_arm64`, etc.
        public let attributes: [String: String]

        public var isOnline: Bool { state == "device" }
        public var isEmulator: Bool { serial.hasPrefix("emulator-") }
        public var model: String? { attributes["model"] }
        public var product: String? { attributes["product"] }
    }

    /// `adb -s <serial> forward tcp:0 tcp:<remote>`. Returns the
    /// dynamically assigned local port.
    public func forward(serial: String, remotePort: Int) throws -> Int {
        let output = try run(args: ["-s", serial, "forward", "tcp:0", "tcp:\(remotePort)"])
        guard let port = Self.parseForwardPort(output.stdout) else {
            let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError.portForwardFailed(
                serial: serial,
                underlying: "Unexpected adb forward output: \(trimmed)"
            )
        }
        return port
    }

    /// Parses the port number from `adb forward tcp:0 tcp:<remote>`
    /// stdout. The common case is a bare numeric line, but certain
    /// adb builds emit status lines first (e.g. "Killed running
    /// adb server\n<port>" when an existing forward gets recycled).
    /// Returns the last non-empty line that parses as a positive
    /// `Int`, or nil if no such line exists.
    static func parseForwardPort(_ output: String) -> Int? {
        for rawLine in output.split(separator: "\n").reversed() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let port = Int(trimmed), port > 0 {
                return port
            }
            // Hit a non-empty, non-numeric line before finding a
            // port — give up rather than scanning further back into
            // unrelated chatter.
            return nil
        }
        return nil
    }

    public func forwardRemove(localPort: Int) throws {
        _ = try run(args: ["forward", "--remove", "tcp:\(localPort)"])
    }

    @discardableResult
    public func shell(serial: String, args: [String]) throws -> RunResult {
        return try run(args: ["-s", serial, "shell"] + args)
    }

    @discardableResult
    public func install(serial: String, apkPath: String, reinstall: Bool = true, grantPermissions: Bool = true) throws -> RunResult {
        var args = ["-s", serial, "install"]
        if reinstall { args.append("-r") }
        if grantPermissions { args.append("-g") }
        args.append(apkPath)
        return try run(args: args, timeout: max(defaultTimeout, 60))
    }

    // MARK: - Result types

    public struct RunResult: Equatable, Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32

        public init(stdout: String, stderr: String, exitCode: Int32) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
        }
    }

    // MARK: - Core runner

    @discardableResult
    public func run(args: [String], timeout: TimeInterval? = nil) throws -> RunResult {
        let process = Process()
        let resolvedPath = Self.resolveOnPATH(binaryPath) ?? binaryPath
        process.executableURL = URL(fileURLWithPath: resolvedPath)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain stdout/stderr asynchronously while the child runs.
        // Without this, a child that writes more than the per-pipe
        // kernel buffer (~64 KB) blocks on its next `write(2)` and
        // never exits — `process.isRunning` stays true forever and
        // we time out instead of returning the output. This is the
        // classic "Process + Pipe deadlock" trap.
        let bufferLock = NSLock()
        var outBuffer = Data()
        var errBuffer = Data()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            bufferLock.lock(); outBuffer.append(chunk); bufferLock.unlock()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            bufferLock.lock(); errBuffer.append(chunk); bufferLock.unlock()
        }

        // Wake the calling thread the moment the child exits, instead
        // of polling `process.isRunning` on a 20 ms heartbeat. Foundation
        // invokes `terminationHandler` on a private queue once the
        // process has reaped, so signalling the semaphore there gives us
        // an exit-driven wakeup with no busy-wait. The timeout path is
        // handled by `semaphore.wait(timeout:)` — also kernel-backed.
        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSemaphore.signal() }

        do {
            try process.run()
        } catch {
            // Common failure: binary missing or not executable.
            // macOS reports this as NSCocoaErrorDomain code 4
            // (NSFileNoSuchFileError); other POSIX hosts surface it
            // as ENOENT in NSPOSIXErrorDomain. Map both so CI on
            // Linux behaves the same as a developer's Mac.
            let nsErr = error as NSError
            let isMissing =
                (nsErr.domain == NSCocoaErrorDomain && nsErr.code == 4) ||
                (nsErr.domain == NSPOSIXErrorDomain && nsErr.code == Int(ENOENT))
            if isMissing {
                throw BridgeError.adbMissing
            }
            throw BridgeError.transport(underlying: "Failed to spawn adb: \(error.localizedDescription)", serial: nil)
        }

        let effectiveTimeout = timeout ?? defaultTimeout
        if exitSemaphore.wait(timeout: .now() + effectiveTimeout) == .timedOut {
            process.terminate()
            // Give the child a brief settling window after SIGTERM so
            // the readability handlers can drain residual output and
            // the kernel can release the pipe FDs. Without this wait,
            // throwing immediately would leak the pipes (the GC reaping
            // the dispatch sources can take seconds under load).
            _ = exitSemaphore.wait(timeout: .now() + 0.5)
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw BridgeError.adbFailure(
                command: args.joined(separator: " "),
                exitCode: -1,
                stderr: "timed out after \(effectiveTimeout)s"
            )
        }

        // Detach handlers and drain any residual bytes that haven't
        // flowed through them yet (Foundation queues the EOF chunk
        // separately on some kernels; reading-to-end after exit is a
        // belt-and-suspenders catch-up).
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let outRemainder = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errRemainder = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        bufferLock.lock()
        outBuffer.append(outRemainder)
        errBuffer.append(errRemainder)
        let stdout = String(data: outBuffer, encoding: .utf8) ?? ""
        let stderr = String(data: errBuffer, encoding: .utf8) ?? ""
        bufferLock.unlock()

        if process.terminationStatus != 0 {
            throw BridgeError.adbFailure(
                command: args.joined(separator: " "),
                exitCode: process.terminationStatus,
                stderr: stderr.isEmpty ? stdout : stderr
            )
        }
        return RunResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    /// PATH-resolve a bare command name (no slashes). Returns nil for
    /// already-absolute / relative-with-slash inputs. We do this
    /// ourselves because `Process.executableURL` requires an absolute
    /// URL and won't search PATH for us.
    static func resolveOnPATH(_ name: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard !name.contains("/") else { return nil }
        let pathEnv = env["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        let fm = FileManager.default
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Parsers

    static func parseDevices(_ output: String) -> [Device] {
        var result: [Device] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of devices attached") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }
            let serial = parts[0]
            let state = parts[1]
            var attrs: [String: String] = [:]
            for chunk in parts.dropFirst(2) {
                if let colon = chunk.firstIndex(of: ":") {
                    let key = String(chunk[..<colon])
                    let value = String(chunk[chunk.index(after: colon)...])
                    attrs[key] = value
                }
            }
            result.append(Device(serial: serial, state: state, attributes: attrs))
        }
        return result
    }
}