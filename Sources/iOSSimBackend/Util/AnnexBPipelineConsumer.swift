// SPDX-License-Identifier: Apache-2.0
import Foundation
@preconcurrency import FBControlCore
import SimUseVideo

/// Bridges idb's byte-stream consumer protocol to the shared Annex B → MP4
/// muxer, letting an `FBSimulatorVideoStream` drive `H264MuxingPipeline`
/// exactly as `adb screenrecord`'s stdout already does on Android — which is
/// the arrangement that pipeline was written for.
///
/// idb delivers encoded bytes on its own capture queue. `ingest` parses and
/// appends synchronously under the pipeline's lock, so the producer sees the
/// same natural backpressure the Android path relies on.
final class AnnexBPipelineConsumer: NSObject, FBDataConsumer {
    private let pipeline: H264MuxingPipeline

    init(pipeline: H264MuxingPipeline) {
        self.pipeline = pipeline
        super.init()
    }

    func consumeData(_ data: Data) {
        pipeline.ingest(data)
    }

    func consumeEndOfFile() {
        pipeline.finishIngest()
    }
}
