// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Boot-instance token for the per-UDID HID connection cache.
///
/// Two independent signals, degrading to nil independently:
/// - `launchdSim` — the device's `launchd_sim` process identity.
///   Authoritative: that process's lifetime IS the boot.
/// - `markerModificationDate` — the mtime of
///   `<dataDirectory>/var/run/launchd_bootstrap.plist`. A single stat,
///   but only a proxy: the issue #55 investigation showed CoreSimulator
///   does not reliably rewrite the marker on every boot (observed
///   frozen across reboots on Xcode 27 B4 / CoreSimulator 1169.1 while
///   the same cycle advanced it on other days/runtimes). Fallback only.
struct HIDBootToken: Equatable {
    let launchdSim: LaunchdSimIdentity?
    let markerModificationDate: Date?
}

extension HIDBootToken: CustomStringConvertible {
    var description: String {
        let sim = launchdSim.map { "launchd_sim=\($0.pid)@\($0.startedAt.timeIntervalSince1970)" }
            ?? "launchd_sim=unknown"
        let marker = markerModificationDate.map { "marker=\($0.timeIntervalSince1970)" }
            ?? "marker=unknown"
        return "\(sim) \(marker)"
    }
}

/// Boot-instance identity for the per-UDID HID connection cache.
///
/// A cached `FBSimulatorHID` is only usable against the boot it was
/// created for: its mach port dies with `launchd_sim`. A simulator that
/// is shut down and re-booted under the same UDID still passes
/// `makeSession`'s `state == .booted` re-check, and a send through the
/// dead port either hangs (observed live on Xcode 26.5 / iOS 26.2) or
/// reports success without delivering (issue #55, Xcode 27 B4 /
/// CoreSimulator 1169.1) — so reuse has to be gated before anything is
/// sent, and the gate must not depend on a signal CoreSimulator only
/// sometimes refreshes.
enum HIDBootIdentity {

    /// Whether a cached connection may be reused. Decision table:
    /// 1. Both tokens carry a `launchd_sim` identity → reuse iff equal.
    ///    The marker is ignored: process identity is strictly stronger.
    /// 2. Exactly one side carries it → fail closed. The boot cannot be
    ///    proven unchanged, rebuilding costs milliseconds, and reusing
    ///    a dead port hangs or silently drops input.
    /// 3. Neither side carries it → the previous marker rule: both
    ///    mtimes known and equal.
    static func isReusable(cachedToken: HIDBootToken?, currentToken: HIDBootToken) -> Bool {
        guard let cachedToken else { return false }
        switch (cachedToken.launchdSim, currentToken.launchdSim) {
        case let (cached?, current?):
            return cached == current
        case (nil, nil):
            guard let cachedMarker = cachedToken.markerModificationDate,
                  let currentMarker = currentToken.markerModificationDate
            else { return false }
            return cachedMarker == currentMarker
        default:
            return false
        }
    }

    /// The current boot token for a simulator. The probe is injectable
    /// so the composition is testable without live processes.
    static func token(
        dataDirectory: String?,
        udid: String,
        launchdSimProbe: (String) -> LaunchdSimIdentity? = LaunchdSimLocator.identity(forUDID:)
    ) -> HIDBootToken {
        HIDBootToken(
            launchdSim: launchdSimProbe(udid),
            markerModificationDate: markerModificationDate(dataDirectory: dataDirectory)
        )
    }

    /// The boot marker's modification date, or nil when the marker (or
    /// the data directory itself) is unavailable.
    static func markerModificationDate(dataDirectory: String?) -> Date? {
        guard let dataDirectory else { return nil }
        let markerPath = URL(fileURLWithPath: dataDirectory)
            .appendingPathComponent("var/run/launchd_bootstrap.plist")
            .path
        let attributes = try? FileManager.default.attributesOfItem(atPath: markerPath)
        return attributes?[.modificationDate] as? Date
    }
}
