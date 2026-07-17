// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Thread-safe bridge from a raw H.264 Annex-B byte stream to an MP4 file,
/// shared by the iOS (`FBSimulatorVideoStream`) and Android
/// (`adb screenrecord`) capture paths. Byte chunks arrive on a capture
/// thread; `ingest(_:)` parses and appends them synchronously so the
/// producer sees natural backpressure. A fatal muxer error latches the
/// pipeline closed and is reported once through `onFatalError`.
public final class H264MuxingPipeline: @unchecked Sendable {
    private let recorder: H264PassthroughRecorder
    private let clock: @Sendable () -> TimeInterval
    private let onFatalError: @Sendable (Error) -> Void

    private let lock = NSLock()
    private var parser = AnnexBStreamParser()
    private var fatal = false
    private var closed = false
    private var _framesWritten: Int64 = 0
    private var _firstFrameReceived = false
    private var _lastIngestHostTime: TimeInterval = 0

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
        lock.lock()
        defer { lock.unlock() }
        guard !fatal, !closed else { return }
        let now = clock()
        _lastIngestHostTime = now
        appendLocked(parser.consume(data), hostTime: now)
    }

    /// Start a fresh parser for a new capture segment (Android restarts
    /// `screenrecord` every 180 s on API < 34). The single monotonic clock
    /// keeps PTS continuous across the boundary.
    public func resetParserForNewSegment() {
        lock.lock()
        defer { lock.unlock() }
        parser = AnnexBStreamParser()
    }

    /// Flush the parser's trailing access unit and close the intake. After
    /// this returns, no further `ingest(_:)` will append, so the caller can
    /// safely finalize the recorder. Idempotent.
    public func finishIngest() {
        lock.lock()
        defer { lock.unlock() }
        guard !fatal, !closed else { return }
        closed = true
        // Stamp the trailing frame with when its data actually arrived, not
        // now — the parser holds a frame pending until the next start code, so
        // a static screen's sole keyframe arrives at t≈0 but is only flushed
        // at stop. Using the flush time would pin the first frame's PTS to the
        // stop instant and collapse the clip to zero duration.
        let hostTime = _lastIngestHostTime > 0 ? _lastIngestHostTime : clock()
        appendLocked(parser.flush(), hostTime: hostTime)
    }

    private func appendLocked(_ accessUnits: [H264AccessUnit], hostTime: TimeInterval) {
        guard !accessUnits.isEmpty, let sps = parser.currentSPS, let pps = parser.currentPPS else { return }
        do {
            for accessUnit in accessUnits {
                try recorder.append(accessUnit: accessUnit, sps: sps, pps: pps, hostTime: hostTime)
                _framesWritten += 1
                _firstFrameReceived = true
            }
        } catch {
            fatal = true
            onFatalError(error)
        }
    }

    public var framesWritten: Int64 {
        lock.lock(); defer { lock.unlock() }
        return _framesWritten
    }

    public var firstFrameReceived: Bool {
        lock.lock(); defer { lock.unlock() }
        return _firstFrameReceived
    }

    public var lastIngestHostTime: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return _lastIngestHostTime
    }

    public var hadFatalError: Bool {
        lock.lock(); defer { lock.unlock() }
        return fatal
    }
}
