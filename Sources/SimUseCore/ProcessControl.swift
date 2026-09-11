// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(os)
import os
#endif

/// Synchronous cancellation flag used by the streaming/recording commands.
///
/// The signal-to-finalise path is latency-critical: a process supervisor
/// that follows SIGTERM with a short-grace SIGKILL must reach
/// `recorder.finish()` before the kill lands, otherwise the mp4 trailer
/// (moov atom) is never written. An actor-backed flag adds ~10-100 ms of
/// scheduler jitter on every cancel/check; `OSAllocatedUnfairLock` keeps the
/// handler and loop pickup synchronous.
public final class CancellationFlag: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public func cancel() {
        value.withLock { $0 = true }
    }

    public func isCancelled() -> Bool {
        value.withLock { $0 }
    }
}

/// A latch that transitions to "set" exactly once. Guarantees a
/// `CheckedContinuation` is resumed a single time when two callbacks race
/// (a completion handler versus a timeout).
public final class OnceFlag: Sendable {
    private let fired = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    /// Returns true the first time it is called, false thereafter.
    public func trySet() -> Bool {
        fired.withLock { fired in
            guard !fired else { return false }
            fired = true
            return true
        }
    }
}

/// Thread-safe, set-once error capture for callback-based APIs (e.g.
/// FBFuture completion callbacks).
///
/// The BGRA stream reports failures through completion callbacks on a
/// background queue with no continuation to resume — the stream runs
/// until a signal arrives. The command loop polls this box instead, so
/// the first failure terminates streaming and surfaces as a thrown
/// error rather than being lost to stderr.
public final class FirstErrorBox: Sendable {
    private let stored = OSAllocatedUnfairLock<Error?>(initialState: nil)

    public init() {}

    /// Records `error` unless one is already recorded; later calls are no-ops.
    public func set(_ error: Error) {
        stored.withLock { if $0 == nil { $0 = error } }
    }

    /// The first error recorded, or nil if none has been.
    public var first: Error? {
        stored.withLock { $0 }
    }
}

/// Sleep that wakes early when `flag` is cancelled.
///
/// `Task.sleep` is not interruptible from a signal handler, so a vanilla
/// frame-pacing sleep adds up to one frame interval of latency to the
/// signal-to-finish path. Polling in short chunks bounds that latency.
public func cancellableSleep(seconds: TimeInterval, flag: CancellationFlag) async throws {
    guard seconds > 0 else { return }
    let chunkNanos: UInt64 = 5_000_000 // 5 ms
    let totalNanos = UInt64(seconds * 1_000_000_000)
    var elapsed: UInt64 = 0
    while elapsed < totalNanos {
        if flag.isCancelled() { return }
        let step = min(chunkNanos, totalNanos - elapsed)
        try await Task.sleep(nanoseconds: step)
        elapsed += step
    }
}

public final class SignalObserver {
    private var sources: [DispatchSourceSignal] = []
    private let signals: [Int32]

    public init(signals: [Int32], handler: @escaping @Sendable () -> Void) {
        self.signals = signals
        for signalValue in signals {
            signal(signalValue, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalValue, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            sources.append(source)
        }
    }

    public func invalidate() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for signalValue in signals {
            signal(signalValue, SIG_DFL)
        }
    }

    deinit {
        invalidate()
    }
}
