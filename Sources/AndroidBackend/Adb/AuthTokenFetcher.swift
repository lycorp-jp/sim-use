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
        do {
            let output = try adb.shell(serial: serial, args: [
                "content", "query", "--uri", authUri,
            ])
            if let token = parse(stdout: output.stdout), !token.isEmpty {
                return token
            }
            if outputIndicatesBridgeMissing(output.stdout) {
                throw BridgeError.bridgeNotInstalled(serial: serial)
            }
            throw BridgeError.authTokenUnavailable(serial: serial)
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
        for rawLine in stdout.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: "result=") else { continue }
            let after = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if after.hasPrefix("{") {
                if let data = after.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let inner = json["result"] as? String {
                    return inner
                }
                continue
            }
            return after
        }
        return nil
    }
}