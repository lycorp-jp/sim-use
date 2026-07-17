// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A long-running `adb` child process whose stdout is delivered
/// incrementally as raw binary chunks — the streaming counterpart to
/// `Adb.run`, which buffers all output into a `String` and only returns
/// after exit. Used to pipe `adb exec-out screenrecord --output-format=h264`
/// straight into the H.264 muxer.
///
/// Follows the same drain / termination-semaphore patterns as `Adb.run`
/// (readabilityHandler to avoid the 64 KB pipe deadlock, exit-driven wakeup,
/// ENOENT → `BridgeError.adbMissing`).
public final class AdbStreamingProcess: @unchecked Sendable {
    private let adbPath: String
    private let arguments: [String]
    private let onStdout: @Sendable (Data) -> Void
    private let onStderr: (@Sendable (String) -> Void)?

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let exitSemaphore = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var _stdoutByteCount: Int64 = 0
    private var stderrBuffer = Data()

    public init(
        adbPath: String,
        arguments: [String],
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: (@Sendable (String) -> Void)? = nil
    ) {
        self.adbPath = adbPath
        self.arguments = arguments
        self.onStdout = onStdout
        self.onStderr = onStderr
    }

    public func start() throws {
        let resolvedPath = Adb.resolveOnPATH(adbPath) ?? adbPath
        process.executableURL = URL(fileURLWithPath: resolvedPath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.lock.lock()
            self._stdoutByteCount += Int64(chunk.count)
            self.lock.unlock()
            self.onStdout(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.lock.lock()
            self.stderrBuffer.append(chunk)
            self.lock.unlock()
        }

        process.terminationHandler = { [exitSemaphore] _ in exitSemaphore.signal() }

        do {
            try process.run()
        } catch {
            let nsErr = error as NSError
            let isMissing =
                (nsErr.domain == NSCocoaErrorDomain && nsErr.code == 4) ||
                (nsErr.domain == NSPOSIXErrorDomain && nsErr.code == Int(ENOENT))
            if isMissing {
                throw BridgeError.adbMissing
            }
            throw BridgeError.transport(underlying: "Failed to spawn adb: \(error.localizedDescription)", serial: nil)
        }
    }

    /// Send SIGINT — `screenrecord`'s clean-stop signal (flushes the encoder
    /// and finalizes its output before exiting).
    public func interrupt() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGINT)
    }

    public func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    public var isRunning: Bool { process.isRunning }

    public var stdoutByteCount: Int64 {
        lock.lock(); defer { lock.unlock() }
        return _stdoutByteCount
    }

    public var collectedStderr: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: stderrBuffer, encoding: .utf8) ?? ""
    }

    /// Block until the child exits (or `timeout` elapses), then detach the
    /// handlers and drain any residual stdout. Returns the exit status, or
    /// nil on timeout (after a SIGTERM escalation).
    @discardableResult
    public func waitForExit(timeout: TimeInterval) -> Int32? {
        let timedOut = exitSemaphore.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSemaphore.wait(timeout: .now() + 0.5)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let residual = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !residual.isEmpty {
            lock.lock()
            _stdoutByteCount += Int64(residual.count)
            lock.unlock()
            onStdout(residual)
        }
        let residualErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !residualErr.isEmpty {
            lock.lock()
            stderrBuffer.append(residualErr)
            lock.unlock()
        }
        if let onStderr, !collectedStderr.isEmpty {
            onStderr(collectedStderr)
        }

        return timedOut ? nil : process.terminationStatus
    }
}
