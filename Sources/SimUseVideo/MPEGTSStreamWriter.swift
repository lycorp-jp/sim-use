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
    /// One 90 kHz tick, the smallest step that keeps PTS strictly increasing.
    private static let ptsEpsilon: TimeInterval = 1.0 / 90_000

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
        let tables: Data = state.withLock { state in
            state.lastTablesTime = 0
            return state.muxer.programTables()
        }
        consume(tables)
    }

    /// Emit the program tables plus a clock reference, without waiting for a
    /// picture. Called periodically so a player's clock keeps advancing on a
    /// still screen, and so a consumer attaching mid-stream sees the tables
    /// promptly.
    ///
    /// `hostTime` must be the caller's current clock reading, not the last
    /// picture's: the PCR is what a player builds its own clock from, so it
    /// has to track real elapsed time. Pinning it to the last frame's PTS
    /// leaves it stalled whenever frames arrive slower than the keep-alive
    /// interval, and a stalled clock desynchronises the player — observed as
    /// a picture that tracks fine for a minute and then falls behind, with
    /// the decode queue suddenly filling.
    public func writeKeepAlive(hostTime: TimeInterval) {
        let bytes: Data = state.withLock { state in
            var out = state.muxer.programTables()
            state.lastTablesTime = state.streamTime
            // The clock reference rides the stream's own timeline, not the
            // wall clock. They deliberately diverge across an idle period:
            // if the PCR ran ahead while no pictures were produced, the next
            // picture's PTS would already be in the player's past and it
            // would be discarded as late.
            out.append(state.muxer.clockReference(at: state.streamTime))
            return out
        }
        consume(bytes)
    }

    public func append(accessUnit: H264AccessUnit, sps: Data, pps: Data, hostTime: TimeInterval) throws {
        // Everything that touches the muxer happens under the lock; the
        // consumer is called outside it, because it can block on a pipe and
        // holding the lock across that would stall the capture thread.
        let packets: Data = state.withLock { state in
            // Advance the timeline by the real gap, clamped. Frames arriving
            // in one chunk share an arrival time, so a zero gap still needs
            // one tick to keep PTS strictly increasing.
            if let lastHostTime = state.lastHostTime {
                let gap = min(max(0, hostTime - lastHostTime), Self.maxFrameGap)
                state.streamTime += max(gap, Self.ptsEpsilon)
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
            return out
        }
        consume(packets)
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
