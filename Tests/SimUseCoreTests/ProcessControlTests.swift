// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
@testable import SimUseCore

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

    // The sleep tests run on `ManualClock` and assert on the order of
    // events, not on wall-clock bounds that a loaded CI runner can miss.
    // Each checkpoint races "the sleeper returned" against "the sleeper
    // suspended again"; exactly one of the two happens, so a regression
    // fails at once. The time limit is only a backstop.

    @Test("cancellableSleep wakes at the next chunk once the flag is cancelled", .timeLimit(.minutes(1)))
    func cancellableSleepEarlyWake() async throws {
        let clock = ManualClock()
        let flag = CancellationFlag()
        try await withThrowingTaskGroup(of: SleeperEvent.self) { group in
            group.addTask {
                try await cancellableSleep(for: .seconds(30), flag: flag, clock: clock)
                return .returned
            }
            let started = try await nextSleeperEvent(in: &group, clock: clock)
            try #require(started == .sleeping)

            flag.cancel()
            // One 5 ms chunk of a 30 s sleep: the sleeper must return here
            // instead of sleeping again.
            clock.advance(by: .milliseconds(5))
            let woken = try await nextSleeperEvent(in: &group, clock: clock)
            #expect(woken == .returned)
            group.cancelAll()
        }
        #expect(clock.sleepCount == 1)
    }

    @Test("cancellableSleep returns without sleeping when the flag is already cancelled", .timeLimit(.minutes(1)))
    func cancellableSleepPreCancelled() async throws {
        let clock = ManualClock()
        let flag = CancellationFlag()
        flag.cancel()
        try await withThrowingTaskGroup(of: SleeperEvent.self) { group in
            group.addTask {
                try await cancellableSleep(for: .seconds(30), flag: flag, clock: clock)
                return .returned
            }
            let event = try await nextSleeperEvent(in: &group, clock: clock)
            #expect(event == .returned)
            group.cancelAll()
        }
        #expect(clock.sleepCount == 0)
    }

    @Test("cancellableSleep ends at the clock deadline, not after a count of chunks", .timeLimit(.minutes(1)))
    func cancellableSleepHonoursDeadline() async throws {
        let clock = ManualClock()
        let flag = CancellationFlag()
        try await withThrowingTaskGroup(of: SleeperEvent.self) { group in
            group.addTask {
                try await cancellableSleep(for: .seconds(30), flag: flag, clock: clock)
                return .returned
            }
            let started = try await nextSleeperEvent(in: &group, clock: clock)
            try #require(started == .sleeping)

            // A chunk that wakes 29 s late must not count as 5 ms, and must
            // not end the sleep before the deadline either.
            clock.advance(by: .seconds(29))
            let beforeDeadline = try await nextSleeperEvent(in: &group, clock: clock)
            try #require(beforeDeadline == .sleeping)

            clock.advance(by: .seconds(1))
            let atDeadline = try await nextSleeperEvent(in: &group, clock: clock)
            #expect(atDeadline == .returned)
            group.cancelAll()
        }
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

private enum SleeperEvent {
    case returned
    case sleeping
}

/// Reports what the sleeper child of `group` did after the clock last
/// moved: it returned, or it is suspended in `clock`. One of the two always
/// holds, so the answer does not depend on scheduling. The sleeper child
/// returns `.returned`; the caller cancels the group when it is done.
private func nextSleeperEvent(
    in group: inout ThrowingTaskGroup<SleeperEvent, Error>,
    clock: ManualClock
) async throws -> SleeperEvent {
    group.addTask {
        try await clock.waitForSleeper()
        return .sleeping
    }
    return try #require(try await group.next())
}
