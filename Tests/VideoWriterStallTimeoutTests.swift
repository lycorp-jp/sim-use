// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import AVFoundation
@testable import iOSSimBackend

@Suite("H264StreamRecorder writer-readiness timeout policy")
struct VideoWriterStallTimeoutTests {
    /// Deterministic stand-in for the wall clock: `sleep` advances the
    /// fake instant instead of blocking, so timeout paths run instantly.
    private final class FakeClock {
        private(set) var current = ContinuousClock.now
        private(set) var sleepCalls: [TimeInterval] = []

        func now() -> ContinuousClock.Instant { current }

        func sleep(_ interval: TimeInterval) {
            sleepCalls.append(interval)
            current = current.advanced(by: .seconds(interval))
        }
    }

    @Test("Never-ready input throws VideoWriterStallError once the deadline passes")
    func neverReadyThrowsAfterDeadline() {
        let clock = FakeClock()
        // 0.25 is exactly representable in binary, so 4 polls land the
        // fake clock precisely on the 1 s deadline — no FP drift.
        #expect(throws: VideoWriterStallError(timeout: 1.0)) {
            try H264StreamRecorder.waitUntilReady(
                isReady: { false },
                timeout: 1.0,
                pollInterval: 0.25,
                now: clock.now,
                sleep: clock.sleep
            )
        }
        #expect(clock.sleepCalls.count == 4)
    }

    @Test("Ready input returns immediately without sleeping")
    func readyImmediatelyDoesNotSleep() throws {
        let clock = FakeClock()
        try H264StreamRecorder.waitUntilReady(
            isReady: { true },
            timeout: 1.0,
            now: clock.now,
            sleep: clock.sleep
        )
        #expect(clock.sleepCalls.isEmpty)
    }

    @Test("Input becoming ready after N polls returns after exactly N sleeps")
    func readyAfterNPolls() throws {
        let clock = FakeClock()
        var checks = 0
        try H264StreamRecorder.waitUntilReady(
            isReady: {
                checks += 1
                return checks > 3
            },
            timeout: 1.0,
            pollInterval: 0.005,
            now: clock.now,
            sleep: clock.sleep
        )
        #expect(clock.sleepCalls == [0.005, 0.005, 0.005])
    }

    @Test("Production timeout is generous — a busy but healthy writer never trips it")
    func productionTimeoutIsGenerous() {
        #expect(H264StreamRecorder.readinessTimeout == 10)
    }

    @Test("Stall error message names the timeout and the stalled writer")
    func stallErrorMessageIsDescriptive() {
        let message = VideoWriterStallError(timeout: 10).localizedDescription
        #expect(message.contains("10"))
        #expect(message.lowercased().contains("stall"))
    }

    // Integration: an AVAssetWriterInput whose writer never started
    // reports `isReadyForMoreMediaData == false` forever — the exact
    // shape of a wedged writer. Uses the real clock with a short
    // timeout, so this stays fast and headless.
    @Test("Unstarted AVAssetWriterInput trips the stall timeout")
    func unstartedInputTimesOut() {
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        #expect(throws: VideoWriterStallError(timeout: 0.05)) {
            try H264StreamRecorder.waitUntilReady(
                isReady: { input.isReadyForMoreMediaData },
                timeout: 0.05,
                pollInterval: 0.005
            )
        }
    }
}
