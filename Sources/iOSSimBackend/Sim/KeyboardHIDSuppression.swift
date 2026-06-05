// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Detects the Xcode-27-era `dtuhidd` daemon, which takes over the
/// simulator's HID keyboard service and silently drops the legacy
/// `SimDeviceLegacyHIDClient` keyboard path that `sim-use type` (and the
/// `key` family) rely on. When it is active, HID key injection is a no-op,
/// so callers fail loudly with a pointer to the `paste --via-menu`
/// workaround instead of typing into the void.
///
/// `dtuhidd` runs inside each booted simulator's `launchd_sim` domain, so we
/// scope detection to the target UDID by matching the daemon's parent
/// `launchd_sim` bootstrap path against the device UDID.
///
/// See facebook/idb "Detect when dtuhidd suppresses the legacy keyboard HID"
/// (2026-06). Tracking issue: Xcode 27 support
/// (github.com/lycorp-jp/sim-use/issues/84).
enum KeyboardHIDSuppression {
    /// Environment override: set to a non-empty value to skip the guard and
    /// attempt keyboard HID anyway.
    static let skipCheckEnvVar = "SIM_USE_SKIP_DTUHIDD_CHECK"

    /// True when a `dtuhidd` process is running inside the `launchd_sim`
    /// domain of the given simulator UDID. Returns false (fail open) when the
    /// process table cannot be read.
    static func isSuppressed(forUDID udid: String) -> Bool {
        guard let table = processTable() else { return false }

        // launchd_sim PIDs whose bootstrap path names this UDID.
        let simBootstrapPIDs = Set(
            table
                .filter { $0.command.contains("launchd_sim") && $0.command.contains(udid) }
                .map(\.pid)
        )
        guard !simBootstrapPIDs.isEmpty else { return false }

        return table.contains { process in
            isDtuhidd(process.command) && simBootstrapPIDs.contains(process.ppid)
        }
    }

    /// Actionable message describing the suppression and how to recover.
    static func workaroundMessage(udid: String) -> String {
        """
        Keyboard HID is suppressed by dtuhidd (Xcode 27 / new Simulator runtime).
        `type` is a silent no-op while dtuhidd is active (Device Hub open, or a
        CoreDevice HID client attached): the legacy keyboard HID path is disconnected.

        Fixes, in order of preference:
          1. Quit Device Hub, then re-boot the simulator. A fresh boot with no
             CoreDevice HID client reconnects the legacy keyboard and `type` works
             (verified on iOS 27). A live re-boot is required - the legacy service
             is disconnected at boot, so closing Device Hub alone is not enough:
               xcrun simctl shutdown \(udid) && xcrun simctl boot \(udid)
             (`simctl boot` is headless; `open -a Simulator` shows the window -
             the classic Simulator.app does not trigger dtuhidd, only Device Hub does.)
          2. Or use the touch-driven pasteboard path (bypasses keyboard HID):
               sim-use tap <target> --udid \(udid)
               sim-use paste "<text>" --via-menu --target-id <AXUniqueId> --udid \(udid)

        Set \(skipCheckEnvVar)=1 to attempt typing anyway.
        """
    }

    private static func isDtuhidd(_ command: String) -> Bool {
        command == "dtuhidd"
            || command.hasSuffix("/dtuhidd")
            || command.hasPrefix("/usr/libexec/dtuhidd")
    }

    private struct ProcessEntry {
        let pid: Int32
        let ppid: Int32
        let command: String
    }

    private static func processTable() -> [ProcessEntry]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -axww: every process, full (untruncated) command line.
        process.arguments = ["-axww", "-o", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1])
            else {
                return nil
            }
            return ProcessEntry(pid: pid, ppid: ppid, command: String(parts[2]))
        }
    }
}