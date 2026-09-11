// SPDX-License-Identifier: Apache-2.0
import Foundation
import os

/// POSIX-write sink for streaming bytes to stdout (or any descriptor).
///
/// `FileHandle.write` raises an uncatchable ObjC exception when the consumer
/// closes its end of the pipe (ffplay quit, `head -c` done) — killing the
/// stream with a crash instead of a summary. This sink ignores SIGPIPE and
/// reports the broken pipe through `isBroken`, so the frame/segment loops
/// can treat consumer hangup as an orderly end-of-stream. Thread-safe: the
/// native paths write from a capture callback while the command loop polls
/// `isBroken`.
///
/// A consumer that keeps the pipe open but stops reading never produces
/// EPIPE — the pipe just fills and stays full — and a plain blocking write
/// would then hold the capture thread forever, leaving Ctrl-C nothing to
/// interrupt. So the sink waits for room with `poll` in short slices,
/// consults `shouldAbort` between them, and writes at most `PIPE_BUF` bytes
/// per call: a pipe reports `POLLOUT` only when at least that much room
/// exists, and a write no larger than `PIPE_BUF` completes without blocking
/// once it does.
///
/// It deliberately leaves the descriptor's flags alone. `O_NONBLOCK` lives on
/// the open file description, which stdout shares with the parent shell,
/// with stderr under `2>&1`, and with anything else that inherited the
/// terminal. Setting it here left the user's terminal non-blocking after exit
/// and made stderr writes fail with EAGAIN mid-run.
public final class StdoutStreamSink: Sendable {
    /// Largest write the kernel completes without blocking once `poll` has
    /// reported room on a pipe.
    static let maxWriteLength = Int(PIPE_BUF)
    /// How long one wait for room lasts before cancellation is re-checked.
    private static let pollSliceMilliseconds: Int32 = 100

    private let state = OSAllocatedUnfairLock(initialState: (bytes: UInt64(0), broken: false))
    private let fileDescriptor: Int32
    private let shouldAbort: @Sendable () -> Bool

    /// - Parameters:
    ///   - fileDescriptor: where bytes go; injectable so the blocking
    ///     behaviour can be tested against a pipe nobody drains.
    ///   - shouldAbort: consulted while waiting for room, so a stalled
    ///     consumer cannot pin the writer past cancellation.
    public init(fileDescriptor: Int32 = STDOUT_FILENO, shouldAbort: @escaping @Sendable () -> Bool) {
        signal(SIGPIPE, SIG_IGN)
        self.fileDescriptor = fileDescriptor
        self.shouldAbort = shouldAbort
    }

    public var bytesWritten: UInt64 { state.withLock { $0.bytes } }
    public var isBroken: Bool { state.withLock { $0.broken } }

    /// Write all of `data`. Returns false once the pipe is broken (further
    /// calls are no-ops) or when cancellation interrupted the write.
    @discardableResult
    public func write(_ data: Data) -> Bool {
        guard !isBroken else { return false }
        /// Why a write stopped short: cancellation is not a pipe failure and
        /// must not latch the sink closed.
        enum Outcome { case complete, cancelled, brokenPipe }
        let (outcome, written): (Outcome, Int) = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return (.complete, 0) }
            var written = 0
            while written < buffer.count {
                if shouldAbort() { return (.cancelled, written) }
                var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, Self.pollSliceMilliseconds)
                if ready == 0 { continue }   // No room yet; re-check cancellation.
                if ready < 0 {
                    if errno == EINTR { continue }
                    return (.brokenPipe, written)
                }
                // Any readiness, POLLHUP/POLLERR included, falls through to the
                // write: a reader that went away turns into EPIPE there.
                let length = min(buffer.count - written, Self.maxWriteLength)
                let result = Darwin.write(fileDescriptor, base.advanced(by: written), length)
                if result > 0 {
                    written += result
                    continue
                }
                if result < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                return (.brokenPipe, written)
            }
            return (.complete, written)
        }
        state.withLock { state in
            state.bytes += UInt64(written)
            if outcome == .brokenPipe { state.broken = true }
        }
        return outcome == .complete
    }
}
