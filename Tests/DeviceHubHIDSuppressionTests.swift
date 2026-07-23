// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

// `DeviceHubHIDSuppression` flags simulators whose legacy HID was
// disconnected by being *booted* while Device Hub was open (issue #60).
// The predicate is dtuhidd's start time relative to its parent
// `launchd_sim`: boot-time attach (poisoned, measured 1 s apart) vs a
// later Hub attach (benign, measured ≥ 34 s). Pure decision over an
// injected process table — no live processes.

@Suite("DeviceHubHIDSuppression")
struct DeviceHubHIDSuppressionTests {
    private let udid = "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"
    private let simPID: pid_t = 96_860
    private let bootTime: TimeInterval = 1_784_783_247

    private func record(
        _ pid: pid_t,
        ppid: pid_t,
        startOffset: TimeInterval,
        _ command: String
    ) -> LaunchdSimLocator.ProcessRecord {
        LaunchdSimLocator.ProcessRecord(
            pid: pid,
            ppid: ppid,
            startedAt: Date(timeIntervalSince1970: bootTime + startOffset),
            command: command
        )
    }

    private func launchdSim() -> LaunchdSimLocator.ProcessRecord {
        record(simPID, ppid: 1, startOffset: 0, "launchd_sim")
    }

    private func args(_ blobs: [pid_t: String]) -> (pid_t) -> String? {
        { pid in blobs[pid] }
    }

    private var simArgs: [pid_t: String] {
        [simPID: "launchd_sim\u{0}/Devices/\(udid)/data/var/run/launchd_bootstrap.plist"]
    }

    @Test("dtuhidd spawned with the boot flags suppression (the measured poisoned state)")
    func bootTimeAttachSuppresses() {
        let table = [launchdSim(), record(96_912, ppid: simPID, startOffset: 1, "dtuhidd")]
        #expect(DeviceHubHIDSuppression.isSuppressed(forUDID: udid, in: table, argumentsForPID: args(simArgs)))
    }

    @Test("dtuhidd attached after boot does not flag (the measured benign state)")
    func lateAttachIsBenign() {
        let table = [launchdSim(), record(58_807, ppid: simPID, startOffset: 34, "dtuhidd")]
        #expect(!DeviceHubHIDSuppression.isSuppressed(forUDID: udid, in: table, argumentsForPID: args(simArgs)))
    }

    @Test("The boot-attach window boundary is inclusive")
    func windowBoundaryIsInclusive() {
        let atWindow = [
            launchdSim(),
            record(97_000, ppid: simPID, startOffset: DeviceHubHIDSuppression.bootAttachWindow, "dtuhidd"),
        ]
        let pastWindow = [
            launchdSim(),
            record(97_001, ppid: simPID, startOffset: DeviceHubHIDSuppression.bootAttachWindow + 1, "dtuhidd"),
        ]
        #expect(DeviceHubHIDSuppression.isSuppressed(forUDID: udid, in: atWindow, argumentsForPID: args(simArgs)))
        #expect(!DeviceHubHIDSuppression.isSuppressed(forUDID: udid, in: pastWindow, argumentsForPID: args(simArgs)))
    }

    @Test("dtuhidd under a different simulator's launchd_sim does not flag this one")
    func otherSimulatorsDtuhiddIgnored() {
        let otherSim: pid_t = 50_000
        let table = [
            launchdSim(),
            record(otherSim, ppid: 1, startOffset: 2, "launchd_sim"),
            record(50_100, ppid: otherSim, startOffset: 3, "dtuhidd"),
        ]
        var blobs = simArgs
        blobs[otherSim] = "launchd_sim\u{0}/Devices/00000000-0000-0000-0000-000000000000/data"
        #expect(!DeviceHubHIDSuppression.isSuppressed(forUDID: udid, in: table, argumentsForPID: args(blobs)))
    }

    @Test("No dtuhidd anywhere does not flag")
    func noDtuhiddIsClean() {
        #expect(!DeviceHubHIDSuppression.isSuppressed(forUDID: udid, in: [launchdSim()], argumentsForPID: args(simArgs)))
    }

    @Test("Simulator not booted (no launchd_sim) fails open")
    func missingLaunchdSimFailsOpen() {
        let table = [record(96_912, ppid: simPID, startOffset: 1, "dtuhidd")]
        #expect(!DeviceHubHIDSuppression.isSuppressed(forUDID: udid, in: table, argumentsForPID: args(simArgs)))
    }

    @Test("Full-path dtuhidd command forms are recognized")
    func fullPathCommandForms() {
        let table = [launchdSim(), record(96_912, ppid: simPID, startOffset: 1, "/usr/libexec/dtuhidd")]
        #expect(DeviceHubHIDSuppression.isSuppressed(forUDID: udid, in: table, argumentsForPID: args(simArgs)))
    }

    @Test("The workaround message names the UDID, the reboot fix, and the escape hatch")
    func workaroundMessageContract() {
        let message = DeviceHubHIDSuppression.workaroundMessage(udid: udid)
        #expect(message.contains(udid))
        #expect(message.contains("xcrun simctl shutdown"))
        #expect(message.contains(DeviceHubHIDSuppression.skipCheckEnvVar))
    }
}
