// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Detects a simulator whose legacy HID input was disconnected by the
/// Xcode-27-era `dtuhidd` daemon (Device Hub).
///
/// The disconnection is decided at simulator *boot*: a simulator booted
/// while Device Hub is open loses the legacy `SimDeviceLegacyHIDClient`
/// path — keyboard, and on CoreSimulator 1169.1+ touch as well — so
/// every HID verb reports success while delivering nothing. A simulator
/// booted clean keeps working even if Device Hub attaches later
/// (verified live 2026-07-23, issue #60: same device, same runtime —
/// booted-under-Hub taps silently dropped; Hub attached after a clean
/// boot, taps kept landing).
///
/// dtuhidd's *presence* in the device's `launchd_sim` domain therefore
/// cannot distinguish the two states. Its *start time* can: in the
/// poisoned state `launchd_sim` spawns dtuhidd as part of boot bring-up
/// (measured 1 s apart), while a later Hub attach spawns it whenever
/// the user opens Device Hub (measured ≥ 34 s even with an immediate
/// scripted reopen). `bootAttachWindow` separates the two with margin
/// on both sides, and the failure directions are asymmetric by design:
/// a false positive fails loudly with recovery steps and an env escape
/// hatch, a false negative would silently drop input — so the window
/// leans generous.
///
/// Work record: docs/ai/xxxx-xcode27-support/README.md. Superseded by
/// upstream idb's DTUHID transport once we migrate.
enum DeviceHubHIDSuppression {
    /// Environment override: set to a non-empty value to skip the guard
    /// and attempt legacy HID anyway.
    static let skipCheckEnvVar = "SIM_USE_SKIP_DTUHIDD_CHECK"

    /// dtuhidd starting within this window of its `launchd_sim`'s start
    /// is treated as boot-time attach (the poisoned state). Measured:
    /// poisoned = 1 s, fastest benign reopen = 34 s.
    static let bootAttachWindow: TimeInterval = 15

    /// True when the given simulator was booted with Device Hub open,
    /// i.e. legacy HID sends will silently not land. Returns false
    /// (fail open) when the process table cannot be read — the guard
    /// must never block a working simulator on probe failure.
    static func isSuppressed(forUDID udid: String) -> Bool {
        guard let table = LaunchdSimLocator.processTable() else { return false }
        return isSuppressed(
            forUDID: udid,
            in: table,
            argumentsForPID: LaunchdSimLocator.argumentBlob(forPID:)
        )
    }

    /// Pure decision over an injected process table (unit-tested
    /// without live processes).
    static func isSuppressed(
        forUDID udid: String,
        in table: [LaunchdSimLocator.ProcessRecord],
        argumentsForPID: (pid_t) -> String?
    ) -> Bool {
        guard let sim = LaunchdSimLocator.record(
            forUDID: udid,
            in: table,
            argumentsForPID: argumentsForPID
        ) else { return false }
        return table.contains { process in
            isDtuhidd(process.command)
                && process.ppid == sim.pid
                && process.startedAt.timeIntervalSince(sim.startedAt) <= bootAttachWindow
        }
    }

    /// Actionable message describing the suppression and how to recover.
    static func workaroundMessage(udid: String) -> String {
        """
        Legacy HID input is disconnected for simulator \(udid): it was booted while \
        Device Hub was open (dtuhidd started together with the boot), so touch and \
        keyboard events from sim-use never land even though sends report success.

        Fix: quit Device Hub, then re-boot the simulator:
          xcrun simctl shutdown \(udid) && xcrun simctl boot \(udid)
        A live re-boot is required — the disconnection is decided at boot. Device Hub
        attached to an already-booted simulator is harmless and is not flagged.
        (`simctl boot` is headless; `open -a Simulator` shows the window — the classic
        Simulator.app does not trigger dtuhidd, only Device Hub does.)

        If this detection is wrong for your setup, skip the guard with
          \(skipCheckEnvVar)=1 SIM_USE_NO_DAEMON=1 sim-use <verb> ...
        (SIM_USE_NO_DAEMON=1 matters: the guard runs inside the per-UDID daemon,
        which keeps the environment it was spawned with — alternatively run
        `sim-use daemon stop --device \(udid)` first and re-run with just
        \(skipCheckEnvVar)=1.)
        """
    }

    private static func isDtuhidd(_ command: String) -> Bool {
        // sysctl's p_comm carries the bare name; keep the path forms for
        // callers that feed fuller command strings.
        command == "dtuhidd"
            || command.hasSuffix("/dtuhidd")
            || command.hasPrefix("/usr/libexec/dtuhidd")
    }
}
