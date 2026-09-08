// SPDX-License-Identifier: Apache-2.0
import Foundation
import os

/// Feeds parsed H.264 access units into an `MPEGTSMuxer` and hands the
/// resulting transport-stream packets to a consumer.
///
/// The counterpart to `H264PassthroughRecorder`: same access-unit interface,
/// but the destination is a live byte stream rather than an MP4 file, so it
/// stamps a PTS per picture instead of building a sample table.
public final class MPEGTSStreamWriter: H264AccessUnitSink {
    private struct State {
        var muxer = MPEGTSMuxer()
        /// Arrival time of the previous picture, used to measure the real gap
        /// between consecutive frames.
        var lastHostTime: TimeInterval?
        /// The stream's own timeline, which advances by the real inter-frame
        /// gap but never by more than `maxFrameGap`. See `append`.
        var streamTime: TimeInterval = 0
        /// Stream-relative time of the last PAT/PMT emission.
        var lastTablesTime: TimeInterval = -.infinity
        var framesWritten: Int64 = 0
    }

    private static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    /// Smallest step between two pictures that arrived together.
    ///
    /// A chunk off the capture pipe often carries several access units, which
    /// all share one arrival time, so they need separating. A single 90 kHz
    /// tick is enough to keep PTS strictly increasing but collapses to the
    /// same value in a coarser downstream timebase — `ffmpeg` then rejects
    /// them as non-monotonic when muxing to a file. A millisecond survives
    /// any sane timebase and, at a handful of pictures per chunk, moves the
    /// timeline by single-digit milliseconds.
    private static let minFrameStep: TimeInterval = 0.001

    /// Largest gap the stream's timeline will advance between two pictures,
    /// however long the real pause between them was.
    ///
    /// A live preview's contract is "show me the newest frame", not
    /// "reproduce the wall clock" — that second one is `record-video`'s job,
    /// and it keeps real arrival times for exactly that reason. Capture here
    /// is variable-frame-rate: a still screen produces no frames at all, so
    /// stamping the next picture with its true arrival time opens a hole in
    /// the timeline as long as the pause. A player then has to play through
    /// that hole before it reaches the new picture, which is seen as the
    /// preview running minutes behind after the screen has been idle a
    /// while. Capping the gap keeps the timeline compact, so the newest
    /// picture is always about to be presented.
    private static let maxFrameGap: TimeInterval = 0.2

    private let state: OSAllocatedUnfairLock<State>
    private let consume: @Sendable (Data) -> Void
    private let tableInterval: TimeInterval

    public var framesWritten: Int64 { state.withLock { $0.framesWritten } }

    /// - Parameters:
    ///   - tableInterval: How often to re-emit PAT/PMT. A consumer that
    ///     attaches mid-stream cannot interpret anything until it has seen
    ///     them, so they repeat rather than being sent only once.
    ///   - consume: Receives transport-stream bytes in order. Called on the
    ///     capture thread; may block (writing to a pipe does).
    public init(
        tableInterval: TimeInterval = 1.0,
        consume: @escaping @Sendable (Data) -> Void
    ) {
        self.tableInterval = tableInterval
        self.consume = consume
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    /// Emit the program tables straight away, before any picture has been
    /// parsed. A consumer cannot interpret the stream until it has seen
    /// them, and on a variable-frame-rate source the first frame may be
    /// arbitrarily far off — a still screen produces none at all — so
    /// waiting for one would leave an attached player with nothing to read.
    public func writeProgramTables() {
        state.withLock { state in
            state.lastTablesTime = 0
            consume(state.muxer.programTables())
        }
    }

    /// Re-announce the program tables, without waiting for a picture. Called
    /// periodically so a consumer attaching mid-stream learns the structure
    /// promptly, and so a closed pipe is noticed even while the screen is
    /// still and no pictures are being produced.
    ///
    /// Deliberately carries no clock. A PCR is a sample of the transmission
    /// clock and has to advance; this timeline only advances when a picture
    /// arrives, so during an idle stretch there is no honest value to send.
    /// Repeating the previous one made every following picture arrive against
    /// a clock that had stood still, which ffmpeg reports as `Packet
    /// corrupt` — verified by interleaving keep-alives into an offline mux of
    /// a captured stream: none without, one per picture with. Each picture
    /// carries its own PCR, so the clock is sampled exactly when it moves.
    public func writeKeepAlive() {
        state.withLock { state in
            state.lastTablesTime = state.streamTime
            consume(state.muxer.programTables())
        }
    }

    public func append(accessUnit: H264AccessUnit, sps: Data, pps: Data, hostTime: TimeInterval) throws {
        // Generation and delivery are one critical section on purpose. The
        // muxer stamps continuity counters as it generates, so bytes have to
        // reach the consumer in the order they were generated — a keep-alive
        // that overtook an earlier picture would put those counters on the
        // wire backwards and a receiver would discard packets as duplicates.
        // Releasing the lock before writing also lets a partly written batch
        // have another spliced into it, destroying 188-byte alignment.
        //
        // A blocking write therefore holds the lock and the capture thread
        // waits. That is the backpressure working: with nowhere to put the
        // bytes there is nothing useful to do with more of them.
        state.withLock { state in
            // Advance the timeline by the real gap, clamped. Frames arriving
            // in one chunk share an arrival time, so a zero gap still needs
            // one tick to keep PTS strictly increasing.
            if let lastHostTime = state.lastHostTime {
                let gap = min(max(0, hostTime - lastHostTime), Self.maxFrameGap)
                state.streamTime += max(gap, Self.minFrameStep)
            }
            state.lastHostTime = hostTime
            let pts = state.streamTime

            var out = Data()
            if pts - state.lastTablesTime >= tableInterval {
                out.append(state.muxer.programTables())
                state.lastTablesTime = pts
            }
            out.append(
                state.muxer.packets(
                    annexB: Self.annexB(accessUnit: accessUnit, sps: sps, pps: pps),
                    pts: pts,
                    isIDR: accessUnit.isIDR
                )
            )
            state.framesWritten += 1
            consume(out)
        }
    }

    /// Rebuild Annex B framing for one access unit.
    ///
    /// The parser strips parameter sets out of access units (an MP4 keeps
    /// them in `avcC` instead), but an elementary stream has nowhere else to
    /// put them — so every IDR re-carries SPS and PPS. That is also what
    /// lets a consumer attaching mid-stream decode from the next keyframe
    /// rather than never.
    static func annexB(accessUnit: H264AccessUnit, sps: Data, pps: Data) -> Data {
        var out = Data()
        if accessUnit.isIDR {
            out.append(startCode)
            out.append(sps)
            out.append(startCode)
            out.append(pps)
        }
        for nalu in accessUnit.nalUnits {
            out.append(startCode)
            out.append(nalu.data)
        }
        return out
    }
}
