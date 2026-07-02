// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Boot-instance identity for the per-UDID HID connection cache.
///
/// A cached `FBSimulatorHID` is only usable against the boot it was
/// created for: its mach port dies with `launchd_sim`. A simulator that
/// is shut down and re-booted under the same UDID still passes
/// `makeSession`'s `state == .booted` re-check, and on current
/// SimulatorKit a send through the dead port never invokes its
/// completion (observed live on Xcode 26.5 / iOS 26.2), so the failure
/// cannot even be caught after the fact — reuse has to be gated before
/// anything is sent.
///
/// The token is the modification date of
/// `<dataDirectory>/var/run/launchd_bootstrap.plist`, which
/// CoreSimulator rewrites on every boot. Reading it is a single stat —
/// cheap enough to run on every cache hit — and needs no private API
/// (`FBSimulator.dataDirectory` is public surface).
enum HIDBootIdentity {

    /// Whether a cached connection may be reused. Unknown tokens fail
    /// closed: rebuilding the connection costs milliseconds, while
    /// reusing a dead one hangs the daemon until restart.
    static func isReusable(cachedToken: Date?, currentToken: Date?) -> Bool {
        guard let cachedToken, let currentToken else { return false }
        return cachedToken == currentToken
    }

    /// The current boot token for a simulator, or nil when the marker
    /// (or the data directory itself) is unavailable.
    static func token(dataDirectory: String?) -> Date? {
        guard let dataDirectory else { return nil }
        let markerPath = URL(fileURLWithPath: dataDirectory)
            .appendingPathComponent("var/run/launchd_bootstrap.plist")
            .path
        let attributes = try? FileManager.default.attributesOfItem(atPath: markerPath)
        return attributes?[.modificationDate] as? Date
    }
}
