// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Identity of a booted simulator's `launchd_sim` process.
///
/// Each simulator boot runs exactly one `launchd_sim`, and its lifetime
/// IS the boot: shutdown kills it, the next boot spawns a fresh one. Its
/// `(pid, start time)` therefore identifies a boot instance directly —
/// unlike filesystem markers, whose rewrite semantics proved conditional
/// across CoreSimulator versions (issue #55, see `HIDBootIdentity`).
/// The start time guards against pid reuse between boots.
struct LaunchdSimIdentity: Equatable {
    let pid: pid_t
    let startedAt: Date
}

/// Locates the `launchd_sim` process serving a simulator UDID.
///
/// Matched by exact process name, then scoped to the device by looking
/// for the UDID in the argument blob — `launchd_sim`'s argv names the
/// device's `launchd_bootstrap.plist` path (verified live on Xcode 26.5
/// and 27 B4), the same disambiguation `KeyboardHIDSuppression` relies
/// on. Implemented with `sysctl` instead of spawning `/bin/ps`: ~1–2 ms
/// against a ~1000-process table, cheap enough to probe on every HID
/// verb (`ps` measured ~40 ms).
enum LaunchdSimLocator {

    /// The current boot identity for a UDID, or nil when no matching
    /// `launchd_sim` is visible (not booted, or the process table /
    /// argument blob cannot be read). Never throws: callers treat nil
    /// as "unknown" and fail closed at the reuse decision.
    static func identity(forUDID udid: String) -> LaunchdSimIdentity? {
        guard let table = processTable() else { return nil }
        return identity(forUDID: udid, in: table, argumentsForPID: argumentBlob(forPID:))
    }

    // MARK: - Pure decision (unit-tested without live processes)

    struct ProcessRecord: Equatable {
        let pid: pid_t
        let startedAt: Date
        let command: String
    }

    static func identity(
        forUDID udid: String,
        in table: [ProcessRecord],
        argumentsForPID: (pid_t) -> String?
    ) -> LaunchdSimIdentity? {
        let matches = table
            .filter { $0.command == "launchd_sim" }
            .filter { argumentsForPID($0.pid)?.localizedCaseInsensitiveContains(udid) == true }
        // A dying previous boot can briefly overlap the next boot's
        // launchd_sim; the newest start time is the boot the device is
        // running now.
        guard let current = matches.max(by: { $0.startedAt < $1.startedAt }) else { return nil }
        return LaunchdSimIdentity(pid: current.pid, startedAt: current.startedAt)
    }

    // MARK: - sysctl probes

    private static func processTable() -> [ProcessRecord]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        // The table can grow between the sizing call and the fetch;
        // over-allocate and let the kernel report how much it filled.
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        var bytes = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &procs, &bytes, nil, 0) == 0 else {
            return nil
        }
        return procs.prefix(bytes / MemoryLayout<kinfo_proc>.stride).map { proc in
            ProcessRecord(
                pid: proc.kp_proc.p_pid,
                startedAt: Date(
                    timeIntervalSince1970: TimeInterval(proc.kp_proc.p_starttime.tv_sec)
                        + TimeInterval(proc.kp_proc.p_starttime.tv_usec) / 1_000_000
                ),
                command: commandName(of: proc)
            )
        }
    }

    private static func commandName(of proc: kinfo_proc) -> String {
        withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// The raw `KERN_PROCARGS2` blob (exec path, argv, environment) past
    /// its argc header. The UDID match needs a haystack, not a parse;
    /// interior NULs decode harmlessly. Readable only for same-user
    /// processes — `launchd_sim` always is.
    private static func argumentBlob(forPID pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        let header = MemoryLayout<Int32>.size
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > header else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0, size > header else {
            return nil
        }
        return String(decoding: buffer[header..<size], as: UTF8.self)
    }
}
