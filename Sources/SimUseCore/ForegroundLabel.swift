// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Reconciles the `App:` header label that `describe-ui` shows against
/// the *resolved foreground bundle id*, instead of trusting the raw AX
/// (iOS) / window (Android) root label.
///
/// Motivation (issue #81): on a crash → home-screen transition the
/// accessibility server can return a tree whose root still carries the
/// dying app's label (`App: LINE Dev`) while its children are already
/// the system shell, or an empty label (`App:   402x874`). The header
/// then lies. The foreground bundle id resolved out-of-band (pid →
/// `launchctl` on iOS, the bridge's current package on Android) is the
/// source of truth; this type folds it back into the displayed label.
public enum ForegroundLabel {

    /// System "shell" bundles that are never the app under test. When
    /// the resolved foreground is one of these, the header must say so
    /// (e.g. `SpringBoard`) regardless of any stale app label the tree
    /// carries. Android launchers vary per OEM and are classified by the
    /// Android backend, not by this static table.
    public static let systemShells: [String: String] = [
        "com.apple.springboard": "SpringBoard",
    ]

    /// Friendly display name for a known system-shell bundle id, or nil
    /// for a real app / empty input.
    public static func systemShellName(forBundleId bundleId: String?) -> String? {
        guard let bundleId, !bundleId.isEmpty else { return nil }
        return systemShells[bundleId]
    }

    /// Decide the header label.
    ///
    /// Priority:
    /// 1. resolved foreground is a known system shell → its friendly name
    ///    (overrides a stale app label),
    /// 2. otherwise a non-empty AX/window root label,
    /// 3. otherwise the bundle id itself (better than a blank header),
    /// 4. otherwise the caller's `fallback`.
    public static func reconcile(
        axRootLabel: String?,
        foregroundBundleId: String?,
        fallback: String
    ) -> String {
        if let shell = systemShellName(forBundleId: foregroundBundleId) {
            return shell
        }
        if let label = axRootLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        if let bundleId = foregroundBundleId, !bundleId.isEmpty {
            return bundleId
        }
        return fallback
    }
}