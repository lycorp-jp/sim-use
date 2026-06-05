// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Helpers for the auto-generated `VERSION` constant emitted by
/// `Plugins/VersionPlugin`. `VERSION` is whatever
/// `git describe --tags --always --dirty` returned at build time, so
/// it can be either a clean release tag (`v0.6.0`) or a dev-build
/// descriptor (`v0.5.1-130-gabc-dirty`, `dev`, an SHA, …).
public enum ReleaseVersion {

    /// Normalise `raw` down to the "is this a clean release tag?"
    /// form. `v0.6.0` → `"0.6.0"`; dev / dirty / unparseable inputs
    /// → nil.
    ///
    /// The result is what `BridgeClient.expectedBridgeVersion` gets
    /// at CLI bootstrap, gating the ping-time `bridge_version`
    /// check — only release builds enforce the check so day-to-day
    /// developer workflows (where the CLI is built from a branch tip
    /// but the device runs the last shipped APK) keep working
    /// without needing the `SIM_USE_SKIP_BRIDGE_VERSION_CHECK=1`
    /// env opt-out.
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let stripped = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let pattern = #"^[0-9]+\.[0-9]+\.[0-9]+$"#
        if stripped.range(of: pattern, options: .regularExpression) != nil {
            return stripped
        }
        return nil
    }
}