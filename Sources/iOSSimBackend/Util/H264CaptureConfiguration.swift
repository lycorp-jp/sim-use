// SPDX-License-Identifier: Apache-2.0
import Foundation
@preconcurrency import FBControlCore

extension FBVideoStreamConfiguration {
    /// The H.264 capture configuration shared by `record-video` and
    /// `stream-video`. Both verbs drive the identical framebuffer encode and
    /// differ only in where the encoded bytes land — a muxed MP4 file or
    /// stdout — so the configuration lives in one place rather than being
    /// spelled out twice and drifting.
    static func h264Capture(fps: Int, quality: Int, scale: Double) -> FBVideoStreamConfiguration {
        FBVideoStreamConfiguration(
            format: .compressedVideo(withCodec: .h264, transport: .annexB),
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
