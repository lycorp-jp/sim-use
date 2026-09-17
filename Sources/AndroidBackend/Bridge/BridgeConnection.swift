// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Where this process's bridge traffic goes: the adb server that owns
/// the `adb forward`, and the host that forward listens on.
///
/// Both come from the environment (`ADB_SERVER_SOCKET` and friends, which
/// `adb` itself reads, plus `SIM_USE_BRIDGE_HOST`), so two invocations
/// for the same serial can target different adb servers. Anything cached
/// per serial — a persisted `BridgeSession`, a warm daemon — is only
/// valid for the connection it was created under; `identity` is what
/// those caches record and compare.
public struct BridgeConnection: Equatable, Sendable {
    /// The adb server `adb` will talk to, as configured: the
    /// `ADB_SERVER_SOCKET` spec, else `ANDROID_ADB_SERVER_ADDRESS` /
    /// `ANDROID_ADB_SERVER_PORT`, else `default`.
    public let adbServer: String
    /// Host the bridge's forwarded port is reached on.
    public let bridgeHost: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        func value(_ key: String) -> String? {
            guard let raw = environment[key], !raw.isEmpty else { return nil }
            return raw
        }
        if let socket = value("ADB_SERVER_SOCKET") {
            adbServer = socket
        } else if value("ANDROID_ADB_SERVER_ADDRESS") != nil || value("ANDROID_ADB_SERVER_PORT") != nil {
            adbServer = "tcp:\(value("ANDROID_ADB_SERVER_ADDRESS") ?? "localhost"):\(value("ANDROID_ADB_SERVER_PORT") ?? "5037")"
        } else {
            adbServer = "default"
        }
        bridgeHost = BridgeClient.resolveBridgeHost(environment: environment)
    }

    /// Stable string recorded by persisted sessions and reported by
    /// daemons; equal identities mean the same adb server and bridge host.
    public var identity: String {
        "adb=\(adbServer) host=\(bridgeHost)"
    }

    /// The connection identity a per-device daemon for `udid` depends on:
    /// none for iOS simulator and device UDIDs, the adb connection for
    /// everything else. Scoping is decided by excluding iOS shapes rather
    /// than by `PlatformRouter.looksLikeAndroid`, whose heuristic rejects
    /// real adb serials (wireless-debugging mDNS serials exceed its
    /// 32-character cap) that still reach a daemon. Entry points install
    /// this as `DaemonClient.connectionIdentityProvider`.
    public static func daemonConnectionIdentity(
        udid: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        if PlatformRouter.looksLikeIOSSim(trimmed) || PlatformRouter.looksLikePhysicalIOSDevice(trimmed) {
            return nil
        }
        return BridgeConnection(environment: environment).identity
    }
}
