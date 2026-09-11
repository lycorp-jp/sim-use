// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
@testable import SimUseVideo

/// The sink owns the only blocking call in the streaming path, so whether a
/// stalled consumer can pin the whole command comes down to what it does when
/// the pipe fills.
@Suite("StdoutStreamSink")
struct StdoutStreamSinkTests {
    /// A one-way flag readable from another thread.
    private final class Latch: @unchecked Sendable {
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

        let abort = Latch()
        let returned = Latch()
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

    @Test("the sink leaves the descriptor's flags untouched")
    func descriptorFlagsAreLeftAlone() throws {
        // O_NONBLOCK is a property of the open file description, which stdout
        // shares with the parent shell and, under `2>&1`, with stderr. A sink
        // that set it left the user's terminal non-blocking after exit and
        // made stderr writes fail with EAGAIN mid-run.
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let before = fcntl(fds[1], F_GETFL)

        let sink = StdoutStreamSink(fileDescriptor: fds[1], shouldAbort: { false })
        #expect(sink.write(Data(repeating: 0x43, count: 1024)))
        let after = fcntl(fds[1], F_GETFL)
        // Compare only the flags a process can set: the kernel adds its own
        // "has been written to" marker to F_GETFL after the first write.
        let settable = O_NONBLOCK | O_APPEND | O_ASYNC
        #expect(after & settable == before & settable, "status flags changed from \(before) to \(after)")
        #expect(after & O_NONBLOCK == 0, "the descriptor must stay blocking")
    }

    @Test("every byte reaches a slow reader, in order")
    func slowReaderReceivesEverything() throws {
        // The sink writes in PIPE_BUF-sized pieces so that no single write
        // can block; the pieces still have to add up to the original bytes.
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

        let received = NSMutableData()
        let reader = Thread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fds[0], &buffer, buffer.count)
                if n <= 0 { break }
                received.append(buffer, length: n)
                // Drain slower than the writer fills, so the pipe stays full
                // most of the time and the wait-for-room path is exercised.
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
        reader.start()

        let sink = StdoutStreamSink(fileDescriptor: fds[1], shouldAbort: { false })
        #expect(sink.write(payload))
        #expect(sink.bytesWritten == UInt64(payload.count))
        close(fds[1])

        let deadline = Date().addingTimeInterval(5)
        while !reader.isFinished && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        close(fds[0])
        #expect(received as Data == payload, "reader got \(received.length) bytes, expected \(payload.count)")
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
