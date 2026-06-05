// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import ArgumentParser
import Foundation
import Testing
@testable import SimUseCore

// Regression coverage for LINEIOS-216940: `sim-use batch --stdin` was
// unusable in 0.4.0 because the daemon child process is spawned with
// stdin pinned to /dev/null (DaemonClient.spawnDaemon). The daemon
// therefore read zero step lines and threw `ValidationError("No
// executable steps found.")`, which surfaced as the opaque
// `ArgumentParser.ValidationError error 1` wrapper.
//
// `--file <relative>` shares the same root cause for a different
// reason: the daemon's CWD is not the caller's, so a relative path
// that resolves on the client side becomes a missing file once
// forwarded. Both modes must bypass the daemon.
//
// The fix mirrors `Paste`'s `daemonBypass: useStdin` from 0.4.0
// (Paste.swift:48) — same problem, same shape.

@Suite("Batch — daemonBypass on input modes that cannot survive a daemon round-trip")
struct BatchDaemonBypassTests {
    @Test("--stdin bypasses the daemon (otherwise daemon reads /dev/null and errors)")
    func stdinBypassesDaemon() throws {
        let cmd = try IOSSimBatchCommand.parse(["--stdin", "--udid", "FAKE-UDID"])
        #expect(cmd.daemonBypass == true)
    }

    @Test("--file bypasses the daemon (daemon CWD differs from caller's, breaks relative paths)")
    func fileBypassesDaemon() throws {
        let cmd = try IOSSimBatchCommand.parse(["--file", "./steps.txt", "--udid", "FAKE-UDID"])
        #expect(cmd.daemonBypass == true)
    }

    @Test("--file with absolute path also bypasses (kept symmetric with relative)")
    func absoluteFileBypassesDaemon() throws {
        let cmd = try IOSSimBatchCommand.parse(["--file", "/tmp/steps.txt", "--udid", "FAKE-UDID"])
        #expect(cmd.daemonBypass == true)
    }

    @Test("--step flags do not bypass the daemon")
    func stepDoesNotBypassDaemon() throws {
        let cmd = try IOSSimBatchCommand.parse(["--step", "tap -x 1 -y 1", "--udid", "FAKE-UDID"])
        #expect(cmd.daemonBypass == false)
    }

    @Test("multiple --step flags do not bypass the daemon")
    func multipleStepsDoNotBypassDaemon() throws {
        let cmd = try IOSSimBatchCommand.parse([
            "--step", "tap -x 1 -y 1",
            "--step", "tap -x 2 -y 2",
            "--udid", "FAKE-UDID"
        ])
        #expect(cmd.daemonBypass == false)
    }
}