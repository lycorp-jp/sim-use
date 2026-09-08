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
    /// A knowing deviation from the transport's clock model, kept because the
    /// standards-shaped alternative was measured and is worse. A wall-clock
    /// timeline with the clock sampled every 40 ms through the idle stretch
    /// left the preview unrecovered 30 s after both a 10 s and a 30 s pause;
    /// capping the gap recovers in 0.45 s and 0.51 s.
    ///
    /// The reason is that ffplay holds the current picture for a duration it
    /// derives from the *next* picture's PTS, so a wall-clock gap keeps the
    /// stale picture on screen for exactly that long. Sampling the transport
    /// clock does not change that schedule. (Measured against the ffplay
    /// invocation the README documents; other consumers may schedule
    /// differently.)
    ///
    /// The cost, stated plainly: PCR repetition exceeds the 100 ms the
    /// standard allows whenever the screen is still, because a timeline that
    /// only advances on a picture has no honest clock value to send in
    /// between — and restating the previous one made ffmpeg report every
    /// following picture as corrupt. Fine for a preview; not for a broadcast
    /// mux. The resuming picture declares a discontinuity so a
    /// clock-disciplining receiver knows to resynchronise. `record-video`
    /// keeps real elapsed time for anyone who needs it.
    private static let maxFrameGap: TimeInterval = 0.2

    private let state: OSAllocatedUnfairLock<State>
    private let consume: @Sendable (Data) -> Void

    public var framesWritten: Int64 { state.withLock { $0.framesWritten } }

    /// - Parameter consume: Receives transport-stream bytes in order. Called
    ///   on the caller's thread and may block, which is the backpressure.
    public init(consume: @escaping @Sendable (Data) -> Void) {
        self.consume = consume
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    /// Announce the program structure. Called once before the first picture
    /// and periodically after, which serves three purposes: a consumer
    /// attaching mid-stream can learn the structure, reaching the pipe is how
    /// a closed one gets noticed, and on a variable-frame-rate source the
    /// first picture may never come at all.
    ///
    /// Deliberately carries no clock. A PCR is a sample of the transmission
    /// clock and has to advance; this timeline only advances when a picture
    /// arrives, so during an idle stretch there is no honest value to send.
    /// Repeating the previous one made ffmpeg report every following picture
    /// as corrupt. Each picture carries its own PCR instead.
    public func emitProgramTables() {
        state.withLock { state in
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
            // A gap longer than the cap means the screen was idle and the
            // timeline is about to skip real elapsed time. That has to be
            // declared, not just done: the clock this picture arrives
            // against is genuinely not continuous with the last one.
            var discontinuity = false
            if let lastHostTime = state.lastHostTime {
                let realGap = max(0, hostTime - lastHostTime)
                discontinuity = realGap > Self.maxFrameGap
                state.streamTime += max(min(realGap, Self.maxFrameGap), Self.minFrameStep)
            }
            state.lastHostTime = hostTime
            let pts = state.streamTime

            var out = Data()
            out.append(
                state.muxer.packets(
                    annexB: Self.annexB(accessUnit: accessUnit, sps: sps, pps: pps),
                    pts: pts,
                    isIDR: accessUnit.isIDR,
                    discontinuity: discontinuity
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
