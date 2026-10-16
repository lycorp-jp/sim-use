// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One finished `xcrun devicectl … --json-output -` run. The probes that
/// read CoreDevice state about a simulator (`ResizableAppSessionProbe`,
/// `SimulatorDisplayTopologyProbe`) classify this value, so every shape
/// they handle can be pinned in tests without CoreDevice.
public struct DevicectlQueryOutput: Sendable {
    public let terminationStatus: Int32
    public let stdout: Data
    public let stderr: Data

    public init(terminationStatus: Int32, stdout: Data, stderr: Data) {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.stderr = stderr
    }

    /// devicectl writes its JSON document on success *and* on failure, so
    /// callers trust the document rather than the exit status.
    public var document: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any]
    }

    /// stderr then stdout, trimmed — for "unknown subcommand" detection
    /// and error messages.
    public var combinedText: String {
        let text = (String(data: stderr, encoding: .utf8) ?? "") + (String(data: stdout, encoding: .utf8) ?? "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when devicectl rejected the subcommand itself — an older Xcode
    /// that does not know it. Callers remember this for the process life.
    public var isUnknownSubcommand: Bool {
        let text = combinedText
        return text.localizedCaseInsensitiveContains("unrecognized subcommand")
            || text.localizedCaseInsensitiveContains("unknown subcommand")
            || text.localizedCaseInsensitiveContains("unexpected argument")
    }

    /// `"<domain> error <code>: <description>"` for a devicectl error
    /// document, or nil when the document carries no `error`.
    public var errorSummary: (code: Int?, summary: String)? {
        guard let error = document?["error"] as? [String: Any] else { return nil }
        let code = DevicectlQuery.number(error["code"]).map { Int($0) }
        let description = ((error["userInfo"] as? [String: Any])?["NSLocalizedDescription"] as? [String: Any])?["string"] as? String
        let domain = (error["domain"] as? String) ?? "CoreDevice"
        return (code, "\(domain) error \(code.map(String.init) ?? "?")\(description.map { ": \($0)" } ?? "")")
    }
}

/// Runs devicectl (through `xcrun`, so the selected Xcode's devicectl) and
/// captures both streams.
public enum DevicectlQuery {
    /// Spawns the process and waits for it. Returns nil only when the
    /// process cannot be spawned; `spawnError` receives the reason.
    /// `executablePath` is injectable so tests can drive the drain against
    /// `/bin/sh`; production uses `xcrun`.
    public static func run(
        arguments: [String],
        executablePath: String = "/usr/bin/xcrun",
        spawnError: ((String) -> Void)? = nil
    ) -> DevicectlQueryOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain both pipes while the child runs so neither can fill the
        // ~64 KB pipe buffer and deadlock `waitUntilExit()`. Same drain as
        // `SimctlDeviceLister.runSimctl` and `Devicectl.run`.
        let bufferLock = NSLock()
        var outBuffer = Data()
        var errBuffer = Data()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            bufferLock.lock(); outBuffer.append(chunk); bufferLock.unlock()
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            bufferLock.lock(); errBuffer.append(chunk); bufferLock.unlock()
        }

        do {
            try process.run()
        } catch {
            spawnError?("could not spawn xcrun devicectl: \(error.localizedDescription)")
            return nil
        }
        process.waitUntilExit()

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        bufferLock.lock()
        outBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
        errBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
        bufferLock.unlock()

        return DevicectlQueryOutput(terminationStatus: process.terminationStatus, stdout: outBuffer, stderr: errBuffer)
    }

    static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
