// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Cross-platform identifier for one connected device sim-use can target —
/// an iOS Simulator runtime from `simctl list devices`, or an Android
/// device / emulator from `adb devices`. The two platforms originally
/// shipped with separate listing commands (`list-simulators`,
/// `android devices`) and ad-hoc output shapes; `Device` is the unified
/// row that the top-level `sim-use devices` verb emits so external
/// tooling (the Viewer, future IDE integrations, agents) only needs one
/// schema.
///
/// `state` is intentionally a free-form string: iOS reports
/// `Booted` / `Shutdown` / `Shutting Down` / `Booting` / `Creating`, and
/// Android reports `device` / `offline` / `unauthorized`. Callers that
/// just want "can I act on this now?" should use `isUsable`, which
/// applies the per-platform rule.
public struct Device: Codable, Equatable, Hashable, Sendable {
    /// Custom keys for transitional dual-key device-id encoding. The
    /// `udid` key is the historic name; `deviceId` is the new
    /// cross-platform synonym. Until Phase 2 drops `udid`, we emit
    /// both and accept either on decode (preferring `deviceId`).
    private enum CodingKeys: String, CodingKey {
        case udid
        case deviceId
        case name
        case platform
        case state
        case runtime
    }

    public enum Platform: String, Codable, Sendable, CaseIterable {
        case ios
        case android
    }

    /// Platform-state strings as the underlying tools emit them.
    /// Extracted as named constants so a future renaming of an iOS
    /// state ("Booted" → something else in a future simctl) or an
    /// Android one is a single-source change instead of grepping
    /// for the literal across Device, SimctlDeviceLister, Devices,
    /// DeviceModelTests.
    public enum State {
        public static let iosBooted = "Booted"
        public static let iosShutdown = "Shutdown"
        public static let androidOnline = "device"
        public static let androidOffline = "offline"
        public static let androidUnauthorized = "unauthorized"
    }

    public let udid: String
    public let name: String
    public let platform: Platform
    public let state: String
    /// Human-readable runtime label. iOS: the simctl runtime
    /// (`iOS 18.6`, `watchOS 26.1`); Android: `Android` (we don't fetch
    /// the OS version via adb to keep `devices` cheap). Nil when the
    /// platform genuinely has none to report.
    public let runtime: String?

    public init(
        udid: String,
        name: String,
        platform: Platform,
        state: String,
        runtime: String?
    ) {
        self.udid = udid
        self.name = name
        self.platform = platform
        self.state = state
        self.runtime = runtime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        let udid = try c.decodeIfPresent(String.self, forKey: .udid)
        guard let resolved = deviceId ?? udid else {
            throw DecodingError.keyNotFound(
                CodingKeys.deviceId,
                .init(codingPath: decoder.codingPath, debugDescription: "Device payload missing both `deviceId` and `udid`.")
            )
        }
        self.udid = resolved
        self.name = try c.decode(String.self, forKey: .name)
        self.platform = try c.decode(Platform.self, forKey: .platform)
        self.state = try c.decode(String.self, forKey: .state)
        self.runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Emit both keys during the transition. Drop `udid` in Phase 2
        // once known consumers (Viewer, agent scripts, dashboards) all
        // read `deviceId`.
        try c.encode(udid, forKey: .udid)
        try c.encode(udid, forKey: .deviceId)
        try c.encode(name, forKey: .name)
        try c.encode(platform, forKey: .platform)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(runtime, forKey: .runtime)
    }

    /// Whether sim-use can talk to this device right now. iOS: only
    /// `Booted` sims accept HID + a11y. Android: `device` is the online
    /// state; `offline` / `unauthorized` aren't reachable through the
    /// bridge.
    public var isUsable: Bool {
        switch platform {
        case .ios:     return state == State.iosBooted
        case .android: return state == State.androidOnline
        }
    }
}