// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
@testable import AndroidBackend

/// The sink owns the only blocking call in the streaming path, so whether a
/// stalled consumer can pin the whole command comes down to what it does when
/// the pipe fills.
@Suite("StdoutStreamSink")
struct StdoutStreamSinkTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    private final class Done: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    @Test("a consumer that stops reading does not pin the writer")
    func stalledConsumerIsInterruptible() throws {
        // A reader that holds the pipe open but never drains it. This is the
        // case a closed pipe does not cover: no EPIPE ever arrives, the pipe
        // simply fills and stays full.
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }

        let abort = Flag()
        let returned = Done()
        let sink = StdoutStreamSink(fileDescriptor: fds[1], shouldAbort: { abort.isSet })

        // Far more than any pipe buffer, so the write cannot complete.
        let payload = Data(repeating: 0x41, count: 4 << 20)
        let writer = Thread {
            _ = sink.write(payload)
            returned.set()
        }
        writer.start()

        Thread.sleep(forTimeInterval: 0.4)
        #expect(!returned.isSet, "the write should still be waiting on a full pipe")

        // Cancellation — what SIGINT/SIGTERM turns into. The write has to
        // notice, or the command cannot shut down and reap adb.
        abort.set()
        let deadline = Date().addingTimeInterval(3)
        while !returned.isSet && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(returned.isSet, "write never returned after cancellation — the command would hang past Ctrl-C")
    }

    @Test("a closed reader still reports the pipe as broken")
    func closedReaderIsReportedBroken() throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let sink = StdoutStreamSink(fileDescriptor: fds[1], shouldAbort: { false })
        close(fds[0])
        defer { close(fds[1]) }

        // EPIPE is a real end-of-consumer, distinct from cancellation, and
        // the orderly-stop path keys off it.
        let ok = sink.write(Data(repeating: 0x42, count: 1024))
        #expect(!ok, "writing to a closed reader must fail")
        #expect(sink.isBroken, "a closed reader must mark the sink broken")
    }
}
