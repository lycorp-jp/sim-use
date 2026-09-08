// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
@testable import SimUseVideo

/// The writer serves two producers at once — the capture thread appending
/// pictures and the command loop emitting keep-alives — and both share one
/// muxer's continuity counters. These tests pin the property that makes the
/// output decodable: bytes must reach the consumer in the order the muxer
/// generated them, with each batch intact.
@Suite("MPEGTSStreamWriter")
struct MPEGTSStreamWriterTests {
    /// Records every batch handed to it, and how long each `consume` was
    /// inside the writer, so a test can detect interleaving.
    private final class RecordingSink: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var batches: [Data] = []
        private let delay: TimeInterval

        init(delay: TimeInterval = 0) { self.delay = delay }

        func consume(_ data: Data) {
            // Simulate a slow pipe: a real stdout write can block, which is
            // exactly when interleaving would show up.
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            lock.lock()
            batches.append(data)
            lock.unlock()
        }

        var joined: Data {
            lock.lock(); defer { lock.unlock() }
            return batches.reduce(into: Data()) { $0.append($1) }
        }
    }

    /// Counts how many `consume` calls are ever in flight at once. Whether a
    /// race happens to interleave on a given run is luck; whether the writer
    /// *permits* two concurrent writes is a property, and this measures it
    /// directly.
    private final class OverlapDetectingSink: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = 0
        private(set) var maxConcurrent = 0

        func consume(_ data: Data) {
            lock.lock()
            inFlight += 1
            maxConcurrent = max(maxConcurrent, inFlight)
            lock.unlock()
            // Stand in for a blocking stdout write.
            Thread.sleep(forTimeInterval: 0.002)
            lock.lock()
            inFlight -= 1
            lock.unlock()
        }
    }

    private func accessUnit(isIDR: Bool, bytes: Int) -> H264AccessUnit {
        let type: UInt8 = isIDR ? 5 : 1
        var data = Data([type])
        data.append(Data(repeating: 0x77, count: bytes))
        return H264AccessUnit(nalUnits: [H264NALUnit(type: type, data: data)], isIDR: isIDR)
    }

    private let sps = Data([0x67, 0x42, 0x00, 0x1F])
    private let pps = Data([0x68, 0xCE, 0x3C, 0x80])

    /// Walk the stream and report any place a payload-bearing packet breaks
    /// its PID's continuity. A receiver treats that as loss and discards.
    private func continuityBreaks(in stream: Data) -> Int {
        var last: [UInt16: UInt8] = [:]
        var breaks = 0
        var offset = 0
        while offset + 188 <= stream.count {
            let base = stream.startIndex + offset
            guard stream[base] == 0x47 else { return Int.max }   // misalignment
            let pid = (UInt16(stream[base + 1] & 0x1F) << 8) | UInt16(stream[base + 2])
            let afc = (stream[base + 3] >> 4) & 0x03
            let cc = stream[base + 3] & 0x0F
            if afc == 1 || afc == 3 {
                if let previous = last[pid], cc != (previous &+ 1) & 0x0F { breaks += 1 }
                last[pid] = cc
            }
            offset += 188
        }
        return breaks
    }

    /// Count PCR samples in a stream, per PID.
    private func pcrValues(in stream: Data) -> [UInt64] {
        var out: [UInt64] = []
        var offset = 0
        while offset + 188 <= stream.count {
            let b = stream.startIndex + offset
            let afc = (stream[b + 3] >> 4) & 0x03
            if (afc == 2 || afc == 3), stream[b + 4] > 0, stream[b + 5] & 0x10 != 0 {
                out.append(
                    (UInt64(stream[b + 6]) << 25) | (UInt64(stream[b + 7]) << 17)
                    | (UInt64(stream[b + 8]) << 9) | (UInt64(stream[b + 9]) << 1)
                    | (UInt64(stream[b + 10]) >> 7)
                )
            }
            offset += 188
        }
        return out
    }

    @Test("a keep-alive does not restate the clock")
    func keepAliveCarriesNoClock() throws {
        // The PCR is a sample of the transmission clock and must advance.
        // The preview timeline deliberately does not advance while the screen
        // is still, so a keep-alive has no honest clock value to send —
        // repeating the previous one made ffmpeg report every subsequent
        // picture as `Packet corrupt`. Announcing structure without a clock
        // is the coherent option.
        let sink = RecordingSink()
        let writer = MPEGTSStreamWriter(consume: { sink.consume($0) })
        writer.writeProgramTables()
        try writer.append(accessUnit: accessUnit(isIDR: true, bytes: 600),
                          sps: sps, pps: pps, hostTime: 0)
        let afterFrame = pcrValues(in: sink.joined).count

        for _ in 0..<5 { writer.writeKeepAlive() }
        #expect(
            pcrValues(in: sink.joined).count == afterFrame,
            "keep-alives added PCR samples the timeline cannot justify"
        )

        // PCRs that do appear — one per picture — must strictly advance.
        try writer.append(accessUnit: accessUnit(isIDR: false, bytes: 600),
                          sps: sps, pps: pps, hostTime: 0.05)
        let pcrs = pcrValues(in: sink.joined)
        #expect(pcrs == pcrs.sorted() && Set(pcrs).count == pcrs.count,
                "PCR samples must be strictly increasing, got \(pcrs)")
    }

    @Test("every emitted batch is whole packets and the stream stays aligned")
    func batchesAreWholePackets() throws {
        let sink = RecordingSink()
        let writer = MPEGTSStreamWriter(consume: { sink.consume($0) })
        writer.writeProgramTables()
        for i in 0..<20 {
            try writer.append(accessUnit: accessUnit(isIDR: i == 0, bytes: 900),
                              sps: sps, pps: pps, hostTime: Double(i) * 0.03)
        }
        for batch in sink.batches {
            #expect(batch.count % 188 == 0, "a batch of \(batch.count) bytes is not whole TS packets")
            #expect(batch.first == 0x47, "batch does not begin on a packet boundary")
        }
        #expect(continuityBreaks(in: sink.joined) == 0, "continuity broke in a single-threaded run")
    }

    @Test("writes are serialised, so two producers cannot interleave a batch")
    func writesAreSerialised() throws {
        // Byte order is the whole contract here: the muxer stamps continuity
        // counters as it generates, so if two batches reach the consumer in
        // the other order the counters arrive backwards and a receiver
        // discards packets. Worse, a partially written batch with another
        // batch spliced into it destroys 188-byte alignment outright.
        let sink = OverlapDetectingSink()
        let writer = MPEGTSStreamWriter(consume: { sink.consume($0) })
        writer.writeProgramTables()

        let appender = Thread {
            for i in 0..<40 {
                try? writer.append(accessUnit: self.accessUnit(isIDR: i % 20 == 0, bytes: 1500),
                                   sps: self.sps, pps: self.pps,
                                   hostTime: Double(i) * 0.03)
            }
        }
        let keeper = Thread {
            for i in 0..<40 { writer.writeKeepAlive() }
        }
        appender.start(); keeper.start()
        while !appender.isFinished || !keeper.isFinished { Thread.sleep(forTimeInterval: 0.01) }

        #expect(
            sink.maxConcurrent == 1,
            "\(sink.maxConcurrent) writes were in flight at once — the stream can be interleaved"
        )
    }

    @Test("concurrent appends and keep-alives do not reorder the stream")
    func concurrentProducersStayOrdered() throws {
        // Real threads, not a task group: `append` and `writeKeepAlive` are
        // synchronous, so two child tasks with no suspension point would run
        // one after the other and prove nothing. This mirrors
        // AndroidStreamVideoCommand, where the adb read callback appends
        // pictures while the command loop emits keep-alives.
        //
        // The slow sink widens the window that matters: if a batch is
        // generated under one lock and written after releasing it, a second
        // producer can reach the consumer first, and the muxer's continuity
        // counters then arrive out of order.
        let sink = RecordingSink(delay: 0.001)
        let writer = MPEGTSStreamWriter(consume: { sink.consume($0) })
        writer.writeProgramTables()

        let appender = Thread {
            for i in 0..<80 {
                try? writer.append(accessUnit: self.accessUnit(isIDR: i % 30 == 0, bytes: 1500),
                                   sps: self.sps, pps: self.pps,
                                   hostTime: Double(i) * 0.03)
            }
        }
        let keeper = Thread {
            for i in 0..<80 {
                writer.writeKeepAlive()
            }
        }
        appender.start()
        keeper.start()
        while !appender.isFinished || !keeper.isFinished {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let stream = sink.joined
        #expect(stream.count % 188 == 0, "stream is not a whole number of packets")
        let breaks = continuityBreaks(in: stream)
        #expect(breaks == 0, "\(breaks) continuity breaks — batches reached the consumer out of order")
    }
}
