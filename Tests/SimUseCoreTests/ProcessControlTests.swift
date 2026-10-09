// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import SimUseCore

/// Pins the process-control primitives the streaming/recording commands
/// hang their stop paths on.
@Suite("ProcessControl primitives")
struct ProcessControlTests {
    @Test("OnceFlag fires exactly once across concurrent setters")
    func onceFlagSingleWinner() async {
        let flag = OnceFlag()
        let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<32 {
                group.addTask { flag.trySet() }
            }
            var count = 0
            for await won in group where won {
                count += 1
            }
            return count
        }
        #expect(winners == 1)
        #expect(flag.trySet() == false)
    }

    // The sleep tests run on `ManualClock`, so they assert on the order of
    // events, not on wall-clock bounds that a loaded CI runner can miss.
    // The time limit only stops a broken loop that sleeps forever: the
    // sleeper runs as a child task, so the limit's cancellation unwinds it.

    @Test("cancellableSleep wakes at the next chunk once the flag is cancelled", .timeLimit(.minutes(1)))
    func cancellableSleepEarlyWake() async throws {
        let clock = ManualClock()
        let flag = CancellationFlag()
        async let sleeper: Void = cancellableSleep(for: .seconds(30), flag: flag, clock: clock)
        try await clock.waitForSleeper()
        flag.cancel()
        // One 5 ms chunk of a 30 s sleep: the sleeper must return here
        // instead of sleeping again.
        clock.advance(by: .milliseconds(5))
        try await sleeper
        #expect(clock.sleepCount == 1)
    }

    @Test("cancellableSleep returns without sleeping when the flag is already cancelled", .timeLimit(.minutes(1)))
    func cancellableSleepPreCancelled() async throws {
        let clock = ManualClock()
        let flag = CancellationFlag()
        flag.cancel()
        try await cancellableSleep(for: .seconds(30), flag: flag, clock: clock)
        #expect(clock.sleepCount == 0)
    }

    @Test("cancellableSleep ends at the clock deadline, not after a count of chunks", .timeLimit(.minutes(1)))
    func cancellableSleepHonoursDeadline() async throws {
        let clock = ManualClock()
        let flag = CancellationFlag()
        async let sleeper: Void = cancellableSleep(for: .seconds(30), flag: flag, clock: clock)
        // A chunk that wakes 29 s late must not count as 5 ms, and must
        // not end the sleep before the deadline either.
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(29))
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        try await sleeper
        #expect(clock.sleepCount == 2)
    }

    @Test("cancellableSleep returns immediately for non-positive durations")
    func cancellableSleepZero() async throws {
        let flag = CancellationFlag()
        try await cancellableSleep(seconds: 0, flag: flag)
        try await cancellableSleep(seconds: -1, flag: flag)
    }

    @Test("CancellationFlag is sticky")
    func cancellationFlagSticky() {
        let flag = CancellationFlag()
        #expect(!flag.isCancelled())
        flag.cancel()
        flag.cancel()
        #expect(flag.isCancelled())
    }
}

