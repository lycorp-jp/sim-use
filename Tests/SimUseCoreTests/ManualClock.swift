// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A clock that moves only when the test calls `advance(by:)`, so tests of
/// clock-driven code assert on the order of events instead of on wall time.
///
/// Every suspension honours task cancellation, so a test that waits on a
/// sleeper which never arrives or never wakes ends at its time limit
/// instead of hanging the test process.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private enum Wait {
        case sleep(until: Instant)
        case sleeperArrival
    }

    private struct Waiter {
        let wait: Wait
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var waiters: [UInt64: Waiter] = [:]
    private var nextID: UInt64 = 0
    private var sleeps = 0

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    /// Number of `sleep(until:tolerance:)` calls that suspended.
    var sleepCount: Int { lock.withLock { sleeps } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await suspend(.sleep(until: deadline))
    }

    /// Returns once a task is suspended in `sleep(until:tolerance:)`.
    func waitForSleeper() async throws {
        try await suspend(.sleeperArrival)
    }

    /// Moves the clock forward and wakes every sleeper whose deadline passed.
    func advance(by duration: Duration) {
        let due: [Waiter] = lock.withLock {
            current = current.advanced(by: duration)
            let dueIDs = waiters.compactMap { id, waiter in
                if case .sleep(let deadline) = waiter.wait, deadline <= current { return id }
                return nil
            }
            return dueIDs.compactMap { waiters.removeValue(forKey: $0) }
        }
        due.forEach { $0.continuation.resume() }
    }

    private func suspend(_ wait: Wait) async throws {
        let id: UInt64 = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                register(Waiter(wait: wait, continuation: continuation), id: id)
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    private func register(_ waiter: Waiter, id: UInt64) {
        enum Outcome {
            case cancelled
            case ready
            case suspended(wake: [Waiter])
        }
        // The cancellation flag is set before `onCancel` runs, so checking it
        // under the lock closes the race with a cancel that lands before
        // this waiter is stored.
        let outcome: Outcome = lock.withLock {
            if Task.isCancelled { return .cancelled }
            switch waiter.wait {
            case .sleep(let deadline):
                guard current < deadline else { return .ready }
                sleeps += 1
                waiters[id] = waiter
                let arrivalIDs = waiters.compactMap { id, waiter in
                    if case .sleeperArrival = waiter.wait { return id }
                    return nil
                }
                return .suspended(wake: arrivalIDs.compactMap { waiters.removeValue(forKey: $0) })
            case .sleeperArrival:
                let hasSleeper = waiters.values.contains { waiter in
                    if case .sleep = waiter.wait { return true }
                    return false
                }
                if hasSleeper { return .ready }
                waiters[id] = waiter
                return .suspended(wake: [])
            }
        }
        switch outcome {
        case .cancelled:
            waiter.continuation.resume(throwing: CancellationError())
        case .ready:
            waiter.continuation.resume()
        case .suspended(let wake):
            wake.forEach { $0.continuation.resume() }
        }
    }
}
