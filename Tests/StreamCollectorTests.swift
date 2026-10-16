// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
import Foundation
import Testing

// The viewer's subprocess output collector (review S6-002). A reader
// callback that has taken the child's last bytes off the pipe must append
// them before `finish()` returns, and `finish()` must not wait for a
// writer that never closes (an inherited grandchild).

@Suite("StreamCollector")
struct StreamCollectorTests {
    @Test("bytes a reader callback already took are in the result of finish()")
    func inFlightReaderIsKept() async throws {
        let pipe = Pipe()
        let readerTook = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let collector = StreamCollector(handle: pipe.fileHandleForReading, afterRead: {
            readerTook.signal()
            release.wait()
        })
        pipe.fileHandleForWriting.write(Data("boom".utf8))
        // The reader has the bytes and is paused before it records them.
        #expect(readerTook.wait(timeout: .now() + 5) == .success)

        let result = Box()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result.data = collector.finish()
            finished.signal()
        }
        // finish() must wait for the reader rather than return without it.
        #expect(finished.wait(timeout: .now() + 0.3) == .timedOut)
        release.signal()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(result.data == Data("boom".utf8))
        try pipe.fileHandleForWriting.close()
    }

    @Test("finish() returns what is in the pipe while a writer stays open")
    func openWriterDoesNotBlock() throws {
        let pipe = Pipe()
        let collector = StreamCollector(handle: pipe.fileHandleForReading)
        pipe.fileHandleForWriting.write(Data("tail".utf8))
        let started = Date()
        let data = collector.finish()
        #expect(Date().timeIntervalSince(started) < 1)
        // Either the reader or the final drain recorded the bytes.
        #expect(data == Data("tail".utf8))
        try pipe.fileHandleForWriting.close()
    }

    final class Box: @unchecked Sendable { var data = Data() }
}
