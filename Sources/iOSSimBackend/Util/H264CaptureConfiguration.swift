// SPDX-License-Identifier: Apache-2.0
import Foundation
@preconcurrency import FBControlCore

extension FBVideoStreamConfiguration {
    /// The H.264 encoder settings shared by `record-video` and
    /// `stream-video`, so the two verbs cannot drift apart on how the picture
    /// is encoded. What they do not share is `transport`, because the two
    /// sinks need different framing:
    ///
    /// - `.annexB` for the file sink. `H264MuxingPipeline` parses Annex B
    ///   start codes and rebuilds a timeline from host arrival time.
    /// - `.mpegts` for the stdout sink. Annex B carries no presentation
    ///   timestamps, so a player has to guess the frame rate — ffprobe reads
    ///   a bare stream as 25 fps regardless of `--fps`. Feeding a 30 fps
    ///   capture to a consumer that paces at 25 accumulates roughly 5 frames
    ///   of lag per second, unbounded: the picture drifts minutes behind the
    ///   device. MPEG-TS carries PTS/DTS on a 90 kHz clock, so the player
    ///   paces correctly and the queue stays empty.
    static func h264Capture(
        fps: Int,
        quality: Int,
        scale: Double,
        transport: FBVideoStreamTransport
    ) -> FBVideoStreamConfiguration {
        FBVideoStreamConfiguration(
            format: .compressedVideo(withCodec: .h264, transport: transport),
            // Must be non-nil. With no frame rate idb selects a lazy cadence
            // that pushes a frame only when the framebuffer reports damage,
            // so a still screen would deliver nothing at all.
            framesPerSecond: fps,
            rateControl: .quality(Double(quality) / 100.0),
            scaleFactor: scale,
            // A 2 s keyframe interval bounds how long a consumer that joins
            // mid-stream waits for its first decodable picture.
            keyFrameRate: 2.0
        )
    }
}
