// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
import Foundation
import Testing

// Coverage for ViewerAPIHandlers' subprocess-envelope policy. The
// handlers shell out to the sim-use binary; these tests point
// `executable` at a small shell script that emits scripted
// stdout/stderr and exits with a chosen status, so the full policy
// matrix is exercised without a real CLI or simulator:
//
// - `{ok:false}` envelope → forwarded 502 regardless of exit code
//   (CLI domain errors legitimately exit non-zero WITH an envelope);
// - no usable envelope + non-zero exit → 502 carrying stderr (falling
//   back to stdout, then to a generic status message) — previously
//   this either produced a false 200 or a useless NSCocoaErrorDomain
//   string;
// - zero exit → existing success paths, unchanged.
@Suite("ViewerAPIHandlers subprocess policy")
struct ViewerAPIHandlersTests {

    // MARK: - Fixtures

    /// Writes an executable `/bin/sh` script that prints the given
    /// stdout/stderr and exits with `exitCode`, then returns handlers
    /// pointed at it. The script lives in a per-test temp directory
    /// cleaned up by the returned closure.
    private func makeHandlers(
        stdout: String,
        stderr: String = "",
        exitCode: Int32
    ) throws -> (handlers: ViewerAPIHandlers, cleanup: () -> Void) {
        let suffix = String(UUID().uuidString.prefix(6))
        let dir = URL(fileURLWithPath: "/tmp/sim-use-viewer-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake-sim-use")
        var lines = ["#!/bin/sh"]
        // Heredocs keep the JSON fixtures verbatim — no shell quoting
        // pitfalls around the double quotes inside the envelopes.
        if !stdout.isEmpty {
            lines.append("cat <<'STDOUT_EOF'")
            lines.append(stdout)
            lines.append("STDOUT_EOF")
        }
        if !stderr.isEmpty {
            lines.append("cat <<'STDERR_EOF' >&2")
            lines.append(stderr)
            lines.append("STDERR_EOF")
        }
        lines.append("exit \(exitCode)")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        return (
            ViewerAPIHandlers(executable: script),
            { try? FileManager.default.removeItem(at: dir) }
        )
    }

    private func getRequest(query: [String: String] = [:]) -> HTTPRequest {
        HTTPRequest(method: "GET", path: "/api", query: query, headers: [:], body: Data())
    }

    private func tapRequest(deviceId: String = "TEST-UDID", at: Int = 1) throws -> HTTPRequest {
        let body = try JSONSerialization.data(withJSONObject: ["deviceId": deviceId, "at": at])
        return HTTPRequest(method: "POST", path: "/api/tap", query: [:], headers: [:], body: body)
    }

    private func jsonBody(_ response: HTTPResponse) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    // MARK: - Non-zero exit without an envelope surfaces stderr

    @Test("tap: non-zero exit with empty stdout returns stderr, not 200")
    func tapNonZeroExitEmptyStdout() async throws {
        let (handlers, cleanup) = try makeHandlers(stdout: "", stderr: "boom", exitCode: 3)
        defer { cleanup() }
        let response = await handlers.tap(try tapRequest())
        #expect(response.status != 200)
        let body = try jsonBody(response)
        #expect(body["ok"] as? Bool == false)
        let error = try #require(body["error"] as? String)
        #expect(error.contains("boom"))
    }

    @Test("devices: non-zero exit with empty stdout returns stderr, not 200")
    func devicesNonZeroExitEmptyStdout() async throws {
        let (handlers, cleanup) = try makeHandlers(stdout: "", stderr: "boom", exitCode: 3)
        defer { cleanup() }
        let response = await handlers.devices(getRequest())
        #expect(response.status != 200)
        let body = try jsonBody(response)
        #expect(body["ok"] as? Bool == false)
        let error = try #require(body["error"] as? String)
        #expect(error.contains("boom"))
    }

    @Test("snapshot: non-zero exit with empty stdout returns stderr, not 200")
    func snapshotNonZeroExitEmptyStdout() async throws {
        let (handlers, cleanup) = try makeHandlers(stdout: "", stderr: "boom", exitCode: 3)
        defer { cleanup() }
        let response = await handlers.snapshot(getRequest(query: ["deviceId": "TEST-UDID"]))
        #expect(response.status != 200)
        let body = try jsonBody(response)
        #expect(body["ok"] as? Bool == false)
        let error = try #require(body["error"] as? String)
        #expect(error.contains("boom"))
    }

    @Test("tap: non-zero exit with non-JSON stdout falls back to stdout text")
    func tapNonZeroExitFallsBackToStdout() async throws {
        let (handlers, cleanup) = try makeHandlers(stdout: "garbage output", exitCode: 2)
        defer { cleanup() }
        let response = await handlers.tap(try tapRequest())
        #expect(response.status != 200)
        let body = try jsonBody(response)
        #expect(body["ok"] as? Bool == false)
        let error = try #require(body["error"] as? String)
        #expect(error.contains("garbage output"))
    }

    @Test("tap: non-zero exit with no output falls back to a status message")
    func tapNonZeroExitNoOutput() async throws {
        let (handlers, cleanup) = try makeHandlers(stdout: "", exitCode: 4)
        defer { cleanup() }
        let response = await handlers.tap(try tapRequest())
        #expect(response.status != 200)
        let body = try jsonBody(response)
        #expect(body["ok"] as? Bool == false)
        let error = try #require(body["error"] as? String)
        #expect(error.contains("4"))
    }

    // MARK: - False-success regression: JSON object without `ok`

    @Test("tap: non-zero exit with an ok-less JSON object is not a success")
    func tapNonZeroExitUnexpectedShape() async throws {
        let (handlers, cleanup) = try makeHandlers(stdout: #"{"unexpected":"shape"}"#, exitCode: 2)
        defer { cleanup() }
        let response = await handlers.tap(try tapRequest())
        #expect(response.status != 200)
        let body = try jsonBody(response)
        #expect(body["ok"] as? Bool == false)
    }

    // MARK: - `{ok:false}` envelope forwarded regardless of exit code

    @Test("tap: ok:false envelope with non-zero exit forwards error and hint")
    func tapForwardsFailureEnvelope() async throws {
        let (handlers, cleanup) = try makeHandlers(
            stdout: #"{"ok":false,"error":"E","hint":"H"}"#,
            exitCode: 1
        )
        defer { cleanup() }
        let response = await handlers.tap(try tapRequest())
        #expect(response.status == 502)
        let body = try jsonBody(response)
        #expect(body["ok"] as? Bool == false)
        #expect(body["error"] as? String == "E")
        #expect(body["hint"] as? String == "H")
    }

    // MARK: - Zero exit with a good envelope keeps succeeding

    @Test("tap: zero exit with ok:true envelope returns 200")
    func tapSuccess() async throws {
        let (handlers, cleanup) = try makeHandlers(
            stdout: #"{"ok":true,"data":{}}"#,
            exitCode: 0
        )
        defer { cleanup() }
        let response = await handlers.tap(try tapRequest(at: 7))
        #expect(response.status == 200)
        let body = try jsonBody(response)
        #expect(body["ok"] as? Bool == true)
        #expect(body["at"] as? Int == 7)
    }

    @Test("devices: zero exit with ok:true envelope returns 200 with devices")
    func devicesSuccess() async throws {
        let envelope = #"{"ok":true,"data":{"devices":[{"deviceId":"ABC","name":"iPhone","platform":"ios","runtime":"iOS 18.0"}]}}"#
        let (handlers, cleanup) = try makeHandlers(stdout: envelope, exitCode: 0)
        defer { cleanup() }
        let response = await handlers.devices(getRequest())
        #expect(response.status == 200)
        let body = try jsonBody(response)
        #expect(body["ok"] as? Bool == true)
        let devices = try #require(body["devices"] as? [[String: Any]])
        #expect(devices.count == 1)
        #expect(devices.first?["deviceId"] as? String == "ABC")
    }

    @Test("snapshot: rotated iOS outline still carries screen dimensions")
    func snapshotParsesRotatedScreenLine() async throws {
        let envelope = """
        {"ok":true,"data":{"platform":"ios","outline":"App: SampleApp  874x402  (landscape-right)\\n\\n[Top  y<120]\\n","entries":[],"lists":[]}}
        """
        let (handlers, cleanup) = try makeHandlers(stdout: envelope, exitCode: 0)
        defer { cleanup() }

        let response = await handlers.snapshot(getRequest(query: ["deviceId": "TEST-UDID"]))

        #expect(response.status == 200)
        let body = try jsonBody(response)
        #expect(body["ok"] as? Bool == true)
        let screen = try #require(body["screen"] as? [String: Any])
        #expect(screen["appLabel"] as? String == "SampleApp")
        #expect(screen["width"] as? Int == 874)
        #expect(screen["height"] as? Int == 402)
    }
}
