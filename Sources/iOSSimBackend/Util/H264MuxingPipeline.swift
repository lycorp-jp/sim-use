// SPDX-License-Identifier: Apache-2.0
import Foundation
import os
import SimUseCore

/// Thread-safe bridge from a raw H.264 Annex-B byte stream to an MP4 file,
/// shared by the iOS (`FBSimulatorVideoStream`) and Android
/// (`adb screenrecord`) capture paths. Byte chunks arrive on a capture
/// thread; `ingest(_:)` parses and appends them synchronously so the
/// producer sees natural backpressure. A fatal muxer error latches the
/// pipeline closed and is reported once through `onFatalError`.
public final class H264MuxingPipeline: Sendable {
    /// Parser + progress state, confined to the lock. The parser is a
    /// non-Sendable class touched only under this lock.
    private struct State {
        var parser = AnnexBStreamParser()
        var fatal = false
        var closed = false
        var framesWritten: Int64 = 0
        var firstFrameReceived = false
        var lastIngestHostTime: TimeInterval = 0
    }

    private let recorder: H264PassthroughRecorder
    private let clock: @Sendable () -> TimeInterval
    private let onFatalError: @Sendable (Error) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(
        recorder: H264PassthroughRecorder,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onFatalError: @escaping @Sendable (Error) -> Void
    ) {
        self.recorder = recorder
        self.clock = clock
        self.onFatalError = onFatalError
    }

    /// Parse a chunk and append any completed access units. No-op once the
    /// pipeline has been closed by `finishIngest()` or latched by an error.
    public func ingest(_ data: Data) {
        let now = clock()
        state.withLock { state in
            guard !state.fatal, !state.closed else { return }
            state.lastIngestHostTime = now
            let accessUnits = state.parser.consume(data)
            appendLocked(&state, accessUnits: accessUnits, hostTime: now)
        }
    }

    /// Start a fresh parser for a new capture segment (Android restarts
    /// `screenrecord` every 180 s on API < 34). The single monotonic clock
    /// keeps PTS continuous across the boundary.
    public func resetParserForNewSegment() {
        state.withLock { $0.parser = AnnexBStreamParser() }
    }

    /// Flush the parser's trailing access unit and close the intake. After
    /// this returns, no further `ingest(_:)` will append, so the caller can
    /// safely finalize the recorder. Idempotent.
    public func finishIngest() {
        let now = clock()
        state.withLock { state in
            guard !state.fatal, !state.closed else { return }
            state.closed = true
            // Stamp the trailing frame with when its data actually arrived,
            // not now — the parser holds a frame pending until the next start
            // code, so a static screen's sole keyframe arrives at t≈0 but is
            // only flushed at stop. Using the flush time would pin the first
            // frame's PTS to the stop instant and collapse the clip to zero
            // duration.
            let hostTime = state.lastIngestHostTime > 0 ? state.lastIngestHostTime : now
            let accessUnits = state.parser.flush()
            appendLocked(&state, accessUnits: accessUnits, hostTime: hostTime)
        }
    }

    private func appendLocked(_ state: inout State, accessUnits: [H264AccessUnit], hostTime: TimeInterval) {
        guard !accessUnits.isEmpty, let sps = state.parser.currentSPS, let pps = state.parser.currentPPS else { return }
        do {
            for accessUnit in accessUnits {
                try recorder.append(accessUnit: accessUnit, sps: sps, pps: pps, hostTime: hostTime)
                state.framesWritten += 1
                state.firstFrameReceived = true
            }
        } catch {
            state.fatal = true
            onFatalError(error)
        }
    }

    public var framesWritten: Int64 { state.withLock { $0.framesWritten } }
    public var firstFrameReceived: Bool { state.withLock { $0.firstFrameReceived } }
    public var lastIngestHostTime: TimeInterval { state.withLock { $0.lastIngestHostTime } }
    public var hadFatalError: Bool { state.withLock { $0.fatal } }
}
