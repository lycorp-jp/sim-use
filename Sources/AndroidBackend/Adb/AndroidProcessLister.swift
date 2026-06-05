// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Lists the live *main* app processes on an Android device for liveness
/// tracking (issue #81), the Android analogue of iOS's
/// `BundleIdentifierResolver.appSnapshot`.
///
/// Strategy: `adb shell ps -A -o PID,NAME`. A third-party app's main
/// process reports its package name verbatim as the process NAME; child
/// processes append `:subprocess`. We keep only main processes of
/// non-system packages so the liveness signal is "the app's primary
/// process died," not "a recycled push-service worker churned."
public enum AndroidProcessLister {

    /// System / framework package prefixes that are never the app under
    /// test. Filtering them keeps background churn out of the liveness
    /// diff. Conservative on purpose; a real test target never lives
    /// under these.
    static let systemPrefixes = [
        "com.android.",
        "com.google.android.",
        "android.",
    ]

    /// Pure parser over `ps -A -o PID,NAME` output → `[pid: package]`.
    ///
    /// When `installedPackages` is supplied (the device's third-party
    /// package set from `pm list packages -3`) it acts as an allowlist:
    /// only main processes of those packages are kept, which cleanly
    /// drops every system process (`com.google.process.*`, bare
    /// `media.*`, kernel threads). When nil, falls back to the prefix
    /// denylist heuristic so the parser still works without a package
    /// list.
    public static func parse(psOutput: String, installedPackages: Set<String>? = nil) -> [Int: String] {
        var map: [Int: String] = [:]
        for rawLine in psOutput.split(separator: "\n") {
            let columns = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 2, let pid = Int(columns[0]) else { continue }
            let name = String(columns[1])
            // Sub-process (`pkg:worker`) — not the app's main process.
            if name.contains(":") { continue }
            if let allow = installedPackages {
                guard allow.contains(name) else { continue }
            } else {
                // Kernel threads / system_server / paths — not a package.
                if !name.contains(".") || name.contains("/") { continue }
                // System / framework / launcher packages.
                if systemPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            }
            map[pid] = name
        }
        return map
    }

    /// Pure parser over `pm list packages -3` output → set of
    /// third-party package names (`package:<id>` per line).
    public static func parsePackageList(_ output: String) -> Set<String> {
        var packages: Set<String> = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("package:") else { continue }
            let id = String(line.dropFirst("package:".count)).trimmingCharacters(in: .whitespaces)
            if !id.isEmpty { packages.insert(id) }
        }
        return packages
    }

    /// Build an `AppSnapshot` of the device's live app processes, reading
    /// the third-party allowlist fresh every call. Used by `app-state`,
    /// which must reflect the device's true state on demand.
    ///
    /// Returns `nil` when `ps` can't be read (transient adb failure) — a
    /// probe failure is "unknown", distinct from a genuinely empty device,
    /// so the liveness tracker skips the command instead of seeing a
    /// phantom mass-disappearance (issue #81).
    public static func appSnapshot(serial: String, adb: Adb = Adb()) -> AppSnapshot? {
        snapshot(
            serial: serial,
            installedPackages: installedThirdPartyPackages(serial: serial, adb: adb),
            adb: adb
        )
    }

    /// Daemon liveness-probe variant: identical to `appSnapshot` except
    /// the third-party allowlist (`pm list packages -3`, which only
    /// changes on install/uninstall) is served from a short-lived
    /// per-serial cache, removing one `adb shell` round-trip per command.
    /// `ps` is still read fresh, so liveness timing is unaffected and no
    /// false positives are introduced (issue #81 perf follow-up).
    public static func livenessSnapshot(serial: String, adb: Adb = Adb()) -> AppSnapshot? {
        snapshot(
            serial: serial,
            installedPackages: cachedInstalledThirdPartyPackages(serial: serial, adb: adb),
            adb: adb
        )
    }

    /// Read `pm list packages -3` → third-party allowlist, or nil when the
    /// call fails (so `parse` falls back to its prefix heuristic).
    public static func installedThirdPartyPackages(serial: String, adb: Adb = Adb()) -> Set<String>? {
        guard let pm = try? adb.shell(serial: serial, args: ["pm", "list", "packages", "-3"]),
              pm.exitCode == 0
        else { return nil }
        return parsePackageList(pm.stdout)
    }

    /// Shared `ps` read + parse. `nil` only on a `ps` failure; an empty
    /// process map (device genuinely running no tracked apps) is a valid,
    /// non-nil snapshot.
    private static func snapshot(serial: String, installedPackages: Set<String>?, adb: Adb) -> AppSnapshot? {
        guard let result = try? adb.shell(serial: serial, args: ["ps", "-A", "-o", "PID,NAME"]),
              result.exitCode == 0
        else {
            return nil
        }
        return AppSnapshot(appsByPid: parse(psOutput: result.stdout, installedPackages: installedPackages))
    }

    /// Per-serial cache of the third-party allowlist. The daemon serves a
    /// single device one command at a time (`DaemonServer` FIFO chain), so
    /// this unsynchronised access is genuinely single-threaded; the TTL
    /// bounds staleness so a mid-session install is eventually picked up.
    nonisolated(unsafe) private static var packageCache: [String: (packages: Set<String>, at: Date)] = [:]
    static let packageCacheTTL: TimeInterval = 60

    private static func cachedInstalledThirdPartyPackages(serial: String, adb: Adb) -> Set<String>? {
        let now = Date()
        if let hit = packageCache[serial], now.timeIntervalSince(hit.at) < packageCacheTTL {
            return hit.packages
        }
        guard let fresh = installedThirdPartyPackages(serial: serial, adb: adb) else {
            // Transient pm failure: reuse the last good set rather than
            // dropping to the coarser prefix heuristic mid-session.
            return packageCache[serial]?.packages
        }
        packageCache[serial] = (packages: fresh, at: now)
        return fresh
    }
}