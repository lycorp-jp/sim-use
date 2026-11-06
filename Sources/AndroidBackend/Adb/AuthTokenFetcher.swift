// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Fetches the bridge's bearer token via the ContentProvider URI served
/// by the bridge's `service/SimuseContentProvider.kt`, as part of the
/// bootstrap sequence (`AndroidDeviceController.initialize`):
///
/// ```
/// adb -s <serial> shell content query \
///   --uri content://com.linecorp.simuse.devicebridge/auth_token
/// ```
///
/// The reply shape is one of:
///   Row: 0 result={"status":"success","result":"<uuid>"}
///   No result found.
///
/// We extract `<uuid>` defensively — whitespace and exact line wording
/// vary slightly across Android versions / shell variants.
public enum AuthTokenFetcher {
    /// ContentProvider URIs exposed by `SimuseContentProvider.kt`.
    public static let authUri = "content://com.linecorp.simuse.devicebridge/auth_token"
    public static let toggleUri = "content://com.linecorp.simuse.devicebridge/toggle_socket_server"

    public static func fetch(adb: Adb, serial: String) throws -> String {
        try fetchEndpoint(adb: adb, serial: serial).token
    }

    struct Endpoint: Decodable {
        let result: String
        let port: Int?
        let serverError: String?
        let serverState: String?

        enum CodingKeys: String, CodingKey {
            case result, port
            case serverError = "server_error"
            case serverState = "server_state"
        }

        var isPending: Bool { serverState == "starting" || serverState == "stopped" }
        var token: String { result }
        var remotePort: Int { port ?? BridgeClient.defaultRemotePort }
    }

    static func parseEndpoint(
        stdout: String, serial: String? = nil, allowPending: Bool = false
    ) throws -> Endpoint? {
        for line in stdout.split(separator: "\n") {
            guard let range = line.range(of: "result=") else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("{") {
                let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(value.utf8))
                if let error = endpoint.serverError {
                    throw BridgeError.transport(underlying: "Bridge server startup failed: \(error)", serial: serial)
                }
                if allowPending && endpoint.isPending { return endpoint }
                if let state = endpoint.serverState,
                   state != "running" || endpoint.port == nil {
                    throw BridgeError.transport(underlying: "Bridge server is \(state); no active endpoint", serial: serial)
                }
                guard (1...65535).contains(endpoint.remotePort) else {
                    throw BridgeError.malformedEnvelope(underlying: "Invalid bridge port")
                }
                return endpoint
            }
            return Endpoint(result: value, port: nil, serverError: nil, serverState: nil)
        }
        return nil
    }

    /// The timeout is a soft polling budget, not a command deadline. Each adb
    /// query keeps its own timeout and can complete after the polling budget;
    /// a running result is still accepted. This avoids interrupting startup
    /// discovery while the provider waits for the service lifecycle monitor.
    static func fetchEndpoint(
        adb: Adb, serial: String, timeout: TimeInterval = 0, pollInterval: TimeInterval = 0.1
    ) throws -> Endpoint {
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while true {
                let output = try adb.shell(serial: serial, args: [
                    "content", "query", "--uri", authUri,
                ])
                if let endpoint = try parseEndpoint(
                    stdout: output.stdout, serial: serial, allowPending: timeout > 0
                ), !endpoint.token.isEmpty {
                    if endpoint.isPending {
                        let remaining = deadline.timeIntervalSinceNow
                        guard remaining > 0 else {
                            throw BridgeError.transport(
                                underlying: "Bridge server is \(endpoint.serverState ?? "unavailable"); timed out waiting for startup",
                                serial: serial
                            )
                        }
                        Thread.sleep(forTimeInterval: min(max(pollInterval, 0.001), remaining))
                        continue
                    }
                    return endpoint
                }
                if outputIndicatesBridgeMissing(output.stdout) {
                    throw BridgeError.bridgeNotInstalled(serial: serial)
                }
                throw BridgeError.authTokenUnavailable(serial: serial)
            }
        } catch BridgeError.adbFailure(let command, let exitCode, let stderr) {
            // `content query` exits non-zero when the provider is
            // absent on most Android variants; the marker text lands
            // on stderr ("Error while accessing provider:..." /
            // "Unknown URL content://..."). Without this re-classify
            // the user sees a raw adb-failure dump instead of the
            // actionable "run `sim-use android init`" hint, even
            // though the underlying cause is just "bridge APK not
            // installed yet."
            if outputIndicatesBridgeMissing(stderr) {
                throw BridgeError.bridgeNotInstalled(serial: serial)
            }
            throw BridgeError.adbFailure(command: command, exitCode: exitCode, stderr: stderr)
        }
    }

    /// True when `content query` output (stdout or stderr) carries a
    /// platform marker that indicates the bridge ContentProvider is
    /// absent from the device. `case`-insensitive substring match so
    /// minor wording differences across Android versions don't slip
    /// through.
    static func outputIndicatesBridgeMissing(_ output: String) -> Bool {
        let markers = [
            "No result found",
            "Error while accessing provider",
            "Unknown URL",
            "Unknown URI",
        ]
        let lowered = output.lowercased()
        return markers.contains(where: { lowered.contains($0.lowercased()) })
    }

    public static func toggleSocketServer(adb: Adb, serial: String, enabled: Bool) throws {
        let value = enabled ? "true" : "false"
        _ = try adb.shell(serial: serial, args: [
            "content", "insert",
            "--uri", toggleUri,
            "--bind", "enabled:b:\(value)",
        ])
    }

    /// Parse the `content query` output. Handles two known forms:
    ///   - `Row: 0 result={"status":"success","result":"abc-..."}`
    ///   - `Row: 0 result=abc-...` (legacy / raw column form)
    static func parse(stdout: String) -> String? {
        (try? parseEndpoint(stdout: stdout))?.token
    }
}
