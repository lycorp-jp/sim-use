// SPDX-License-Identifier: Apache-2.0
import Foundation
@preconcurrency import FBControlCore

extension FBVideoStreamConfiguration {
    /// The H.264 encoder settings shared by `record-video` and
    /// `stream-video`, so the two verbs cannot drift apart on how the picture
    /// is encoded.
    ///
    /// `transport` is deliberately not shared: the file sink needs `.annexB`
    /// because `H264MuxingPipeline` parses start codes, while the stdout sink
    /// needs `.mpegts` because a bare elementary stream carries no timestamps
    /// for a player to pace off. See `MPEGTSMuxer` for what that costs.
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
