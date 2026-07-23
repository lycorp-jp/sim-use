// SPDX-License-Identifier: Apache-2.0
import Foundation

// HTTP handlers that mirror `Tools/Viewer/server/server.mjs` 1:1. Each
// one shells out to the running `sim-use` binary (via
// `Bundle.main.executablePath`), parses the standard envelope, and
// forwards either `{ok: true, …}` or `{ok: false, error, hint}` back
// to the SPA. Spawning ourselves rather than calling SimUseCore APIs
// directly preserves the existing CLI contract verbatim — the Viewer
// sees exactly what a power user would see at the terminal.

struct ViewerAPIHandlers {
    let executable: URL

    static func resolveSelfExecutable() throws -> URL {
        // `Bundle.main.executablePath` is set for executable targets
        // built with SwiftPM. Use absolute URL so we don't depend on
        // the user's PATH (e.g. for sandboxed launches via `open`).
        if let path = Bundle.main.executablePath {
            return URL(fileURLWithPath: path)
        }
        // Fallback: argv[0] resolved against the current working dir.
        // Should almost never be hit in practice.
        let argv0 = CommandLine.arguments.first ?? "sim-use"
        return URL(fileURLWithPath: argv0)
    }

    // MARK: - GET /api/devices

    func devices(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let result = try await run(arguments: ["devices", "--json"])
            let envelope = parseEnvelope(result.stdout)
            if let failure = failureResponse(envelope: envelope, result: result) {
                return failure
            }
            guard let envelope else {
                return .json(502, ["ok": false, "error": "sim-use devices: bad JSON"])
            }
            let data = (envelope["data"] as? [String: Any]) ?? [:]
            let rawDevices = (data["devices"] as? [[String: Any]]) ?? []
            let simplified: [[String: Any]] = rawDevices.map { d in
                // Prefer the canonical `deviceId` key; fall back to
                // `udid` for compatibility with payloads emitted before
                // the dual-key transition. Only `deviceId` is forwarded
                // downstream — the SPA reads that key exclusively.
                let id = (d["deviceId"] as? String) ?? (d["udid"] as? String) ?? ""
                var slim: [String: Any] = [:]
                slim["deviceId"] = id
                slim["name"] = d["name"] ?? ""
                slim["platform"] = d["platform"] ?? ""
                slim["runtime"] = d["runtime"] ?? ""
                return slim
            }
            return .json(200, ["ok": true, "devices": simplified])
        } catch {
            return .json(500, ["ok": false, "error": String(describing: error)])
        }
    }

    // MARK: - GET /api/snapshot?deviceId=…

    func snapshot(_ request: HTTPRequest) async -> HTTPResponse {
        // Accept either `deviceId` (new) or `udid` (deprecated alias) on
        // the query string.
        let deviceId = (request.query["deviceId"]
            ?? request.query["udid"]
            ?? "").trimmingCharacters(in: .whitespaces)
        guard !deviceId.isEmpty else {
            return .json(400, ["ok": false, "error": "deviceId (or udid) query param is required"])
        }
        do {
            let result = try await run(arguments: ["describe-ui", "--device", deviceId, "--json"], timeout: 30)
            let envelope = parseEnvelope(result.stdout)
            if let failure = failureResponse(envelope: envelope, result: result) {
                return failure
            }
            guard let envelope else {
                return .json(502, ["ok": false, "error": "sim-use describe-ui: bad JSON"])
            }
            let data = (envelope["data"] as? [String: Any]) ?? [:]
            let outline = data["outline"] as? String
            let screen = parseScreenFromOutline(outline)
            var payload: [String: Any] = [
                "ok": true,
                "capturedAt": iso8601Now(),
                "deviceId": deviceId,
                "outline": outline ?? "",
                "entries": data["entries"] ?? [],
                "lists": data["lists"] ?? [],
            ]
            if let platform = data["platform"] {
                payload["platform"] = platform
            }
            if let screen = screen {
                payload["screen"] = screen
            }
            return .json(200, payload)
        } catch {
            return .json(500, ["ok": false, "error": String(describing: error)])
        }
    }

    // MARK: - POST /api/tap

    func tap(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return .json(400, ["ok": false, "error": "body must be JSON object"])
        }
        // Accept either `deviceId` (new) or `udid` (deprecated alias).
        let deviceId = ((body["deviceId"] as? String)
            ?? (body["udid"] as? String)
            ?? "").trimmingCharacters(in: .whitespaces)
        guard !deviceId.isEmpty else {
            return .json(400, ["ok": false, "error": "deviceId (or udid) is required"])
        }
        // The SPA only resolves taps by integer alias (`@N`); other
        // forms (#id, --label, raw coordinates) are intentionally
        // unsupported here — the CLI is the right venue for them.
        guard let at = body["at"] as? Int, at > 0 else {
            return .json(400, ["ok": false, "error": "at must be a positive integer alias"])
        }
        do {
            let result = try await run(arguments: ["tap", "@\(at)", "--device", deviceId, "--json"])
            if let failure = failureResponse(envelope: parseEnvelope(result.stdout), result: result) {
                return failure
            }
            return .json(200, ["ok": true, "at": at])
        } catch {
            return .json(500, ["ok": false, "error": String(describing: error)])
        }
    }

    // MARK: - Subprocess plumbing

    private func run(
        arguments: [String],
        timeout: TimeInterval = 15
    ) async throws -> (stdout: Data, stderr: Data, status: Int32) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Detach the child from our stdin — most sim-use verbs don't
        // read it, and inheriting our (possibly-TTY) stdin can confuse
        // child-side stdin detection.
        process.standardInput = FileHandle.nullDevice

        // Drain stdout/stderr concurrently with the child rather than
        // `readToEnd()` after exit. Critical for verbs that auto-spawn
        // the per-UDID daemon: the daemon inherits these pipe write
        // ends from its parent (the verb process), so after the verb
        // exits the pipes' write side is still held open by the
        // daemon. A post-exit `readToEnd()` would block forever
        // waiting for an EOF that never comes. Streaming via
        // `readabilityHandler` lets us accumulate everything the verb
        // wrote up to its own exit and then bail out as soon as the
        // process terminates.
        let collectedOut = StreamCollector(handle: stdout.fileHandleForReading)
        let collectedErr = StreamCollector(handle: stderr.fileHandleForReading)

        try process.run()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(stdout: Data, stderr: Data, status: Int32), Error>) in
                let timeoutTask = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutTask)
                process.terminationHandler = { proc in
                    timeoutTask.cancel()
                    // Stop draining; whatever's already buffered is
                    // what we ship. Anything the daemon writes later
                    // is not our verb's output anyway.
                    let out = collectedOut.finish()
                    let err = collectedErr.finish()
                    // A normal exit — even non-zero — is the caller's
                    // to interpret via `failureResponse`, so hand back
                    // the exit status alongside the output. Only throw
                    // when the kernel reports the child was killed by
                    // a signal (timeout fired, peer disconnect, etc.).
                    if proc.terminationReason == .exit {
                        continuation.resume(returning: (out, err, proc.terminationStatus))
                    } else {
                        let stderrText = String(data: err, encoding: .utf8) ?? ""
                        let stdoutText = String(data: out, encoding: .utf8) ?? ""
                        let msg = !stderrText.isEmpty ? stderrText : stdoutText
                        continuation.resume(throwing: APIError.subprocessFailed(
                            status: proc.terminationStatus,
                            message: msg.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                    }
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private func parseEnvelope(_ stdout: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any]
    }

    /// Shared failure policy for a completed subprocess. Returns the
    /// response to send when the invocation must be treated as failed,
    /// or nil when the caller may proceed with its success path.
    ///
    /// - An envelope carrying `ok == false` is forwarded verbatim,
    ///   regardless of exit code — CLI domain errors legitimately exit
    ///   non-zero WITH an envelope.
    /// - Without a usable `ok` field (unparseable stdout, non-object
    ///   JSON, or a missing/mistyped `ok`), a non-zero exit means the
    ///   CLI died before producing its envelope: surface its stderr
    ///   (falling back to stdout, then to the bare exit status)
    ///   instead of pretending the verb succeeded.
    private func failureResponse(
        envelope: [String: Any]?,
        result: (stdout: Data, stderr: Data, status: Int32)
    ) -> HTTPResponse? {
        if let envelope, let ok = envelope["ok"] as? Bool {
            return ok ? nil : forwardFailure(envelope)
        }
        guard result.status != 0 else { return nil }
        let stderrText = (String(data: result.stderr, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stdoutText = (String(data: result.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message: String
        if !stderrText.isEmpty {
            message = stderrText
        } else if !stdoutText.isEmpty {
            message = stdoutText
        } else {
            message = "sim-use exited with status \(result.status)"
        }
        return .json(502, ["ok": false, "error": message])
    }

    private func forwardFailure(_ envelope: [String: Any]) -> HTTPResponse {
        // The CLI envelope already carries `error` (always) and
        // optionally `hint`. Pass them through verbatim so the SPA's
        // error banner sees the same text the terminal would.
        var payload: [String: Any] = ["ok": false]
        payload["error"] = envelope["error"] ?? "sim-use reported failure"
        if let hint = envelope["hint"] {
            payload["hint"] = hint
        }
        return .json(502, payload)
    }

    private func parseScreenFromOutline(_ outline: String?) -> [String: Any]? {
        // The first line of `describe-ui --json`'s rendered outline is
        // `App: <label>  WxH`. It's the only place screen dimensions
        // appear in the standard envelope — keeping the parse here
        // means we don't need a new CLI surface to expose them.
        guard let outline,
              let firstNewline = outline.firstIndex(where: { $0.isNewline })
        else { return nil }
        let firstLine = String(outline[..<firstNewline])
        return parseAppLine(firstLine) ?? parseAppLine(outline)
    }

    private func parseAppLine(_ line: String) -> [String: Any]? {
        // Match `App: <label>  WxH` where W and H are integers and
        // `<label>` may contain spaces. iOS outlines append the current
        // device orientation when rotated, e.g. ` (landscape-right)`;
        // accept that suffix while keeping appLabel to the app name.
        let pattern = #"^App:\s+(.*?)\s+(\d+)x(\d+)(?:\s+\([^)]+\))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges == 4,
              let labelRange = Range(match.range(at: 1), in: line),
              let wRange = Range(match.range(at: 2), in: line),
              let hRange = Range(match.range(at: 3), in: line),
              let width = Int(line[wRange]),
              let height = Int(line[hRange])
        else { return nil }
        return [
            "appLabel": String(line[labelRange]),
            "width": width,
            "height": height,
        ]
    }

    private func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

/// Drains a pipe into an in-memory buffer concurrently with the child
/// process. `finish()` detaches the readability handler and returns
/// the buffer accumulated so far — call it from the process's
/// `terminationHandler` to grab everything the child wrote up to its
/// own exit (and not whatever any inherited grandchild keeps writing
/// afterwards).
private final class StreamCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var done = false

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] fh in
            guard let self else { return }
            let chunk = fh.availableData
            if chunk.isEmpty {
                // Pipe writer closed (real EOF). Detach so we stop
                // burning a dispatch source on an empty pipe.
                self.detach()
                return
            }
            self.lock.lock()
            if !self.done {
                self.buffer.append(chunk)
            }
            self.lock.unlock()
        }
    }

    func finish() -> Data {
        detach()
        lock.lock()
        defer { lock.unlock() }
        done = true
        return buffer
    }

    private func detach() {
        handle.readabilityHandler = nil
    }
}

private enum APIError: Error, CustomStringConvertible {
    case subprocessFailed(status: Int32, message: String)

    var description: String {
        switch self {
        case .subprocessFailed(let status, let message):
            return "sim-use exited \(status): \(message)"
        }
    }
}
