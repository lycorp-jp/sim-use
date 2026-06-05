// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Resolves the `CFBundleIdentifier` of a simulator's frontmost app.
///
/// Strategy: read the AX-root element's `pid` (every AX node carries
/// `pid` per the FBSimulatorControl serializer), then look the pid up
/// against `xcrun simctl spawn <udid> launchctl list`. Each row is
/// `<pid> <status> UIKitApplication:<bundleId>[xxxx][xxxx]` for hosted
/// apps; we extract the bundle id from the label.
///
/// Returns empty string when the AX root has no pid, when simctl is
/// unreachable, or when the pid isn't a UIKitApplication. `describe-ui`
/// treats appPackage as hint-grade, not authoritative — failing to
/// resolve is non-fatal.
public enum BundleIdentifierResolver {

    /// Production resolver. Pulls pid from the root element and shells
    /// out to simctl.
    public static func resolve(udid: String, rootElement: AccessibilityElement?) -> String {
        guard let pid = rootElement?.pid, pid > 0 else { return "" }
        guard let output = try? runLaunchctlList(udid: udid) else { return "" }
        return parseForeground(launchctlOutput: output, pid: pid) ?? ""
    }

    /// Foreground resolver that reuses a liveness snapshot when it already
    /// carries the root pid, saving a redundant `launchctl` spawn on the
    /// describe-ui hot path (the daemon probes liveness right before the
    /// command runs — issue #81 perf follow-up). A miss (no root pid, or a
    /// pid the liveness probe excludes — SpringBoard's daemon label) falls
    /// back to a fresh `resolve`, so the crashed-to-home header stays
    /// correct. `cachedSnapshot == nil` (standalone, probe failed, or
    /// detection disabled) is always a fresh resolve — no behavioural
    /// change from the un-cached path.
    public static func resolve(
        udid: String,
        rootElement: AccessibilityElement?,
        cachedSnapshot: AppSnapshot?
    ) -> String {
        if let pid = rootElement?.pid, pid > 0,
           let bundleId = cachedSnapshot?.appsByPid[pid] {
            return bundleId
        }
        return resolve(udid: udid, rootElement: rootElement)
    }

    /// Parser exposed for tests. Returns the bundle id when the input
    /// contains a `UIKitApplication:<bundleId>[…]` row for `pid`.
    ///
    /// The `label` column is conventionally a single whitespace-free
    /// token (launchctl labels never contain spaces — the system
    /// uses dots / hyphens / colons). The `count >= 3` guard
    /// already ensures `columns.last` is non-nil, but `if let`
    /// keeps the destructure honest without the force-unwrap.
    public static func parse(launchctlOutput: String, pid: Int) -> String? {
        for rawLine in launchctlOutput.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("PID") { continue }
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 3 else { continue }
            guard let rowPid = Int(columns[0]), rowPid == pid else { continue }
            guard let last = columns.last else { continue }
            return bundleId(fromLabel: String(last))
        }
        return nil
    }

    /// Parses every *running* `UIKitApplication:` row into a
    /// `[pid: bundleId]` map for liveness tracking. Rows without a
    /// numeric pid (`-`, i.e. installed-but-not-running) and
    /// non-`UIKitApplication` labels (system daemons, including
    /// SpringBoard's daemon label) are excluded, so the map contains
    /// only live hosted apps. Pure; exposed for tests and for building
    /// an `AppSnapshot`.
    public static func appsByPid(launchctlOutput: String) -> [Int: String] {
        var map: [Int: String] = [:]
        for rawLine in launchctlOutput.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("PID") { continue }
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 3,
                  let pid = Int(columns[0]),
                  let last = columns.last,
                  let bundleId = bundleId(fromLabel: String(last))
            else { continue }
            map[pid] = bundleId
        }
        return map
    }

    /// Build an `AppSnapshot` of the simulator's live hosted apps.
    /// Returns `nil` when the `launchctl` spawn fails or times out — a
    /// probe failure is "unknown", distinct from a genuinely empty device.
    /// The liveness tracker treats `nil` as "skip this command" rather
    /// than "everything died", so a transient simctl hiccup can't fake a
    /// mass disappearance (issue #81).
    public static func appSnapshot(udid: String) -> AppSnapshot? {
        guard let output = try? runLaunchctlList(udid: udid) else {
            return nil
        }
        return AppSnapshot(appsByPid: appsByPid(launchctlOutput: output))
    }

    /// SpringBoard runs under the plain daemon label `com.apple.SpringBoard`
    /// (not `UIKitApplication:`), yet it IS the foreground after a
    /// foreground app crashes to the home screen. Map it to its canonical
    /// lowercase bundle id so `ForegroundLabel` can render "SpringBoard"
    /// instead of an empty header (issue #81).
    static let springBoardDaemonLabel = "com.apple.SpringBoard"
    static let springBoardBundleId = "com.apple.springboard"

    /// Foreground-resolution variant of `bundleId(fromLabel:)`: also
    /// recognises SpringBoard's daemon label. Used by `resolve` (header
    /// reconciliation) but NOT by `appsByPid` (liveness), so SpringBoard
    /// is never tracked as an "app under test".
    public static func foregroundBundleId(fromLabel label: String) -> String? {
        if let app = bundleId(fromLabel: label) { return app }
        if label == springBoardDaemonLabel { return springBoardBundleId }
        return nil
    }

    /// Like `parse`, but resolves SpringBoard too (see `foregroundBundleId`).
    public static func parseForeground(launchctlOutput: String, pid: Int) -> String? {
        for rawLine in launchctlOutput.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("PID") { continue }
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 3, let rowPid = Int(columns[0]), rowPid == pid else { continue }
            guard let last = columns.last else { continue }
            return foregroundBundleId(fromLabel: String(last))
        }
        return nil
    }

    /// Pulls `com.example.app` out of `UIKitApplication:com.example.app[1234][...]`.
    /// Returns nil for non-UIKitApplication labels (e.g. system daemons).
    public static func bundleId(fromLabel label: String) -> String? {
        let prefix = "UIKitApplication:"
        guard label.hasPrefix(prefix) else { return nil }
        let trimmed = label.dropFirst(prefix.count)
        if let bracket = trimmed.firstIndex(of: "[") {
            return String(trimmed[..<bracket])
        }
        return String(trimmed)
    }

    // MARK: - simctl bridge

    /// `simctl spawn` can wedge if the target simulator is
    /// mid-boot / mid-shutdown — `waitUntilExit()` then blocks the
    /// describe-ui path indefinitely. The pid-resolution itself is
    /// strictly best-effort (`describe-ui` treats appPackage as a
    /// hint), so cap the spawn at 5 s and treat a timeout as
    /// "couldn't resolve" rather than letting it hang the whole
    /// command.
    private static let launchctlTimeout: TimeInterval = 5

    private static func runLaunchctlList(udid: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "spawn", udid, "launchctl", "list"]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        try process.run()
        let deadline = Date().addingTimeInterval(launchctlTimeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                // Give the child a brief settle so the FDs reap
                // cleanly. Mirrors `Adb.run`'s timeout pattern.
                let killDeadline = Date().addingTimeInterval(0.5)
                while process.isRunning, Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                throw NSError(
                    domain: "BundleIdentifierResolver",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "simctl spawn timed out after \(launchctlTimeout)s"]
                )
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "BundleIdentifierResolver", code: Int(process.terminationStatus))
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}