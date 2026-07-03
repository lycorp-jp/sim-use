// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

/// Pins the record-video stop watchdog policy. The `arm()` side effect
/// (`_exit` from a detached dispatch closure) is not unit-testable, so
/// these tests lock the observable contract instead: a finalization
/// overrun must never masquerade as success (exit 0) and must be
/// explained on stderr.
@Suite("Recording Finish Watchdog Policy")
struct RecordingFinishWatchdogTests {
    @Test("Overrun exits EX_SOFTWARE, not success")
    func exitCodeIsSoftwareError() {
        #expect(RecordingFinishWatchdog.exitCode == 70)
        #expect(RecordingFinishWatchdog.exitCode != 0)
    }

    @Test("Grace window is 3 seconds")
    func gracePeriod() {
        #expect(RecordingFinishWatchdog.gracePeriod == 3.0)
    }

    @Test("Warning names the grace window and the truncation risk")
    func warningMessage() {
        let message = RecordingFinishWatchdog.warningMessage
        #expect(message.hasPrefix("warning:"))
        #expect(message.contains("3s"))
        #expect(message.contains("truncated"))
        #expect(message.hasSuffix("\n"))
    }
}
