// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Common response envelope emitted by every bridge endpoint (built in
/// the bridge's `server/ActionRouter.kt`). Inline JSON `result` (NOT csat's
/// double-encoded string form). On success: `status="success"`, `result`
/// is endpoint-specific. On failure: `status="error"`, `error` is a
/// human message, `code` is a machine-readable token.
public struct BridgeEnvelope<Result: Decodable>: Decodable {
    public let status: String
    public let result: Result?
    public let display: DisplayMetrics?
    public let error: String?
    public let code: String?

    public var isSuccess: Bool { status == "success" }
}

/// Device screen dimensions in pixels, attached to envelopes that need
/// it (currently `/a11y_tree_full`). Distinct from the root node's
/// `boundsInScreen`, which is the **active window**'s rect — for
/// floating popups / dialogs those differ.
public struct DisplayMetrics: Decodable, Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// `/keyboard/state` reply: `{visible, ime_package?}`. `ime_package` is
/// the active IME's package name (e.g. `com.google.android.inputmethod.latin`)
/// when the bridge can read the IME window's root; absent otherwise.
public struct KeyboardStateResult: Decodable, Equatable, Sendable {
    public let visible: Bool
    public let imePackage: String?

    enum CodingKeys: String, CodingKey {
        case visible
        case imePackage = "ime_package"
    }

    public init(visible: Bool, imePackage: String?) {
        self.visible = visible
        self.imePackage = imePackage
    }
}

/// `/ping` reply: `{status, result: "pong", protocol_version, bridge_version}`.
public struct PingResult: Decodable, Equatable, Sendable {
    public let result: String
    public let protocolVersion: Int
    public let bridgeVersion: String

    enum CodingKeys: String, CodingKey {
        case result
        case protocolVersion = "protocol_version"
        case bridgeVersion = "bridge_version"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decode(String.self, forKey: .result)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        bridgeVersion = try container.decode(String.self, forKey: .bridgeVersion)
    }

    public init(result: String, protocolVersion: Int, bridgeVersion: String) {
        self.result = result
        self.protocolVersion = protocolVersion
        self.bridgeVersion = bridgeVersion
    }
}

/// Locale- and OS-dependent strings sit inside several associated
/// values here (`transport(underlying:)`, `adbFailure(stderr:)`,
/// `malformedEnvelope(underlying:)`), so an auto-synthesised
/// `Equatable` would be flaky across runners that surface different
/// `URLError` / `localizedDescription` text. Drop the conformance —
/// callers pattern-match the case (`case .adbMissing = error`)
/// instead of comparing instances for equality.
public enum BridgeError: Error, LocalizedError, HintProviding {
    case adbMissing
    case adbFailure(command: String, exitCode: Int32, stderr: String)
    case deviceOffline(serial: String)
    case bridgeNotInstalled(serial: String)
    case portForwardFailed(serial: String, underlying: String)
    case authTokenUnavailable(serial: String)
    case httpStatus(code: Int, body: String)
    /// A connection-level failure talking to the bridge over `adb
    /// forward` (URLSession error, non-HTTP response). `serial` is the
    /// device the client was bound to, carried so `hint` can name the
    /// exact `sim-use android init --device <serial>` to run. It is nil
    /// for transport failures that aren't tied to a reachable device
    /// (URL construction, missing APK during `init` itself) — those
    /// carry their own actionable message in `underlying`.
    case transport(underlying: String, serial: String?)
    case malformedEnvelope(underlying: String)
    case applicationError(status: String, code: String?, message: String?)
    case protocolMismatch(client: Int, bridge: Int)
    /// The CLI's release version doesn't match the bridge APK's
    /// `versionName`. Raised by `BridgeClient.ping()` when both sides
    /// claim a clean release tag (dev builds skip the check). Distinct
    /// from `protocolMismatch`: the wire spec may still be compatible,
    /// but bug-fix / behaviour drift between mismatched versions can
    /// produce confusing symptoms — tell the user to re-init so the
    /// bundled APK matches the CLI it shipped with.
    case bridgeVersionMismatch(cli: String, bridge: String, udid: String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .adbMissing:
            return "adb is not on PATH. Install Android platform-tools (`brew install --cask android-platform-tools`) or set the SIM_USE_ADB env var."
        case .adbFailure(let command, let exitCode, let stderr):
            return "adb command failed (\(command), exit \(exitCode)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .deviceOffline(let serial):
            return "Android device \(serial) is offline or not authorized."
        case .bridgeNotInstalled(let serial):
            return "sim-use-device-bridge is not installed on \(serial). Run `sim-use android init --device \(serial)`."
        case .portForwardFailed(let serial, let underlying):
            return "Could not establish `adb forward` for \(serial): \(underlying)"
        case .authTokenUnavailable(let serial):
            return "Could not fetch bridge auth token from \(serial). Re-run `sim-use android init --device \(serial)`."
        case .httpStatus(let code, let body):
            return "Bridge returned HTTP \(code): \(body.prefix(200))"
        case .transport(let underlying, _):
            return "Bridge transport error: \(underlying)"
        case .malformedEnvelope(let underlying):
            return "Bridge response was malformed: \(underlying)"
        case .applicationError(let status, let code, let message):
            return "Bridge error (\(code ?? status)): \(message ?? "unknown")"
        case .protocolMismatch(let client, let bridge):
            return "Bridge protocol_version=\(bridge) does not match client expected=\(client). Run `sim-use android init --device <serial>` to upgrade the APK."
        case .bridgeVersionMismatch(let cli, let bridge, _):
            return "sim-use CLI version (\(cli)) does not match the bridge APK installed on the device (\(bridge)). The wire protocol may still work, but behavioural drift between versions can cause subtle bugs — re-init the bridge so the device runs the APK this CLI shipped with."
        case .timeout:
            return "Bridge request timed out."
        }
    }

    public var hint: String? {
        switch self {
        case .applicationError(_, let code, _):
            switch code {
            case "clipboard_write_failed", "paste_unsupported":
                return "use `sim-use type` for plain text — bypasses the clipboard"
            default:
                return nil
            }
        case .bridgeVersionMismatch(_, _, let udid):
            return "Run `sim-use android init --device \(udid)` to reinstall the bundled APK at the version this CLI expects. To bypass the check (advanced — versions are skewed on purpose), set `SIM_USE_SKIP_BRIDGE_VERSION_CHECK=1`."
        case .transport(let underlying, let serial):
            // A connection-level failure on a device whose APK *is*
            // installed (the not-installed case is mapped to
            // `.bridgeNotInstalled` upstream in `BridgeClient`) almost
            // always means the bridge was never fully bootstrapped:
            // a11y service disabled, socket server off, or a stale
            // `adb forward`. The opaque "network connection was lost"
            // gives the caller nothing to act on, so point them at the
            // one command that fixes all three. Gated on the underlying
            // text so genuine mid-session drops on an already-working
            // bridge don't get a misleading "go re-init" nudge — and on
            // `serial` so we only ever name a device we actually know.
            guard let serial, Self.looksLikeBootstrapFailure(underlying) else { return nil }
            return "Bridge may not be bootstrapped on \(serial). Run `sim-use android init --device \(serial)` (or the sim-use-skills preflight) before retrying. Restarting the daemon will not help."
        default:
            return nil
        }
    }

    /// Substrings that mark a `URLSession` connection-level failure
    /// (vs. an HTTP-level error, which surfaces as `.httpStatus` /
    /// `.applicationError`). Matched case-insensitively against the
    /// localized `underlying` so the hint survives locale variation of
    /// the system error text.
    private static func looksLikeBootstrapFailure(_ underlying: String) -> Bool {
        let lowered = underlying.lowercased()
        return lowered.contains("network connection was lost")
            || lowered.contains("could not connect")
            || lowered.contains("connection refused")
            || lowered.contains("connection was refused")
            || lowered.contains("non-http response")
    }
}