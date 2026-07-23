// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

// `LaunchdSimLocator` supplies the authoritative half of the HID boot
// token: the `(pid, start time)` of the `launchd_sim` process serving a
// UDID. The matching logic is pure and tested against fixture tables;
// one smoke test exercises the real sysctl path on the host (no
// simulator required — an unknown UDID simply finds no match).

@Suite("LaunchdSimLocator matching")
struct LaunchdSimLocatorMatchingTests {
    private let udidA = "87FDA16F-2071-4646-AC69-F09063049E78"
    private let udidB = "F728473D-83DE-4406-B8D0-2EECAC3A2DF3"

    private func record(_ pid: pid_t, _ started: TimeInterval, _ command: String) -> LaunchdSimLocator.ProcessRecord {
        LaunchdSimLocator.ProcessRecord(
            pid: pid,
            startedAt: Date(timeIntervalSince1970: started),
            command: command
        )
    }

    /// argv blobs keyed by pid, shaped like KERN_PROCARGS2 content:
    /// exec path + bootstrap plist path naming the device UDID.
    private func arguments(_ blobs: [pid_t: String]) -> (pid_t) -> String? {
        { pid in blobs[pid] }
    }

    @Test("Matches launchd_sim by exact command name and UDID in argv")
    func matchesByCommandAndUDID() {
        let table = [
            record(100, 1_000, "launchd"),
            record(200, 2_000, "launchd_sim"),
            record(300, 3_000, "CoreSimulatorBridge"),
        ]
        let args = arguments([
            200: "launchd_sim\u{0}/Users/dev/Library/Developer/CoreSimulator/Devices/\(udidA)/data/var/run/launchd_bootstrap.plist",
            300: "bridge\u{0}\(udidA)",
        ])
        let identity = LaunchdSimLocator.identity(forUDID: udidA, in: table, argumentsForPID: args)
        #expect(identity == LaunchdSimIdentity(pid: 200, startedAt: Date(timeIntervalSince1970: 2_000)))
    }

    @Test("Ignores processes whose command merely contains launchd_sim")
    func requiresExactCommandName() {
        // grep-style substring matching famously self-matches shell
        // wrappers whose command line quotes "launchd_sim"; the comm
        // field comparison must be exact.
        let table = [record(400, 4_000, "zsh")]
        let args = arguments([400: "zsh -c ps | grep launchd_sim | grep \(udidA)"])
        #expect(LaunchdSimLocator.identity(forUDID: udidA, in: table, argumentsForPID: args) == nil)
    }

    @Test("Picks the right simulator among several booted ones")
    func picksCorrectSimAmongSeveral() {
        let table = [
            record(500, 5_000, "launchd_sim"),
            record(600, 6_000, "launchd_sim"),
        ]
        let args = arguments([
            500: "launchd_sim\u{0}/Devices/\(udidA)/data/var/run/launchd_bootstrap.plist",
            600: "launchd_sim\u{0}/Devices/\(udidB)/data/var/run/launchd_bootstrap.plist",
        ])
        #expect(
            LaunchdSimLocator.identity(forUDID: udidB, in: table, argumentsForPID: args)?.pid == 600
        )
    }

    @Test("UDID match is case-insensitive")
    func udidMatchIsCaseInsensitive() {
        let table = [record(700, 7_000, "launchd_sim")]
        let args = arguments([700: "launchd_sim\u{0}/Devices/\(udidA.lowercased())/data"])
        #expect(LaunchdSimLocator.identity(forUDID: udidA, in: table, argumentsForPID: args) != nil)
    }

    @Test("Overlapping old and new boots resolve to the newest start time")
    func overlappingBootsResolveToNewest() {
        // A dying previous boot's launchd_sim can briefly coexist with
        // the next boot's; the connection must bind to the live one.
        let table = [
            record(800, 8_000, "launchd_sim"),
            record(900, 9_000, "launchd_sim"),
        ]
        let blob = "launchd_sim\u{0}/Devices/\(udidA)/data/var/run/launchd_bootstrap.plist"
        let args = arguments([800: blob, 900: blob])
        #expect(
            LaunchdSimLocator.identity(forUDID: udidA, in: table, argumentsForPID: args)?.pid == 900
        )
    }

    @Test("No matching UDID yields nil")
    func noMatchReturnsNil() {
        let table = [record(1_000, 10_000, "launchd_sim")]
        let args = arguments([1_000: "launchd_sim\u{0}/Devices/\(udidA)/data"])
        #expect(LaunchdSimLocator.identity(forUDID: udidB, in: table, argumentsForPID: args) == nil)
    }

    @Test("Unreadable argument blobs are skipped")
    func unreadableArgumentsSkipped() {
        let table = [record(1_100, 11_000, "launchd_sim")]
        #expect(LaunchdSimLocator.identity(forUDID: udidA, in: table, argumentsForPID: { _ in nil }) == nil)
    }
}

@Suite("LaunchdSimLocator live probe")
struct LaunchdSimLocatorLiveTests {

    @Test("Unknown UDID returns nil against the real process table")
    func liveTableLookupForUnknownUDIDReturnsNil() {
        // Exercises the sysctl path end-to-end on the host. The UDID is
        // random, so no launchd_sim can match — the point is that the
        // probe neither crashes nor hangs and fails to nil cleanly.
        #expect(LaunchdSimLocator.identity(forUDID: UUID().uuidString) == nil)
    }
}
