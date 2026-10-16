// SPDX-License-Identifier: Apache-2.0
import FBControlCore
import FBSimulatorControl
import Foundation

extension FBSimulator {
    /// A video stream of the main display, or of `source` — the display that
    /// hosts the app when it is not the main one (docs/ai/010-display-routing, S5).
    func createStream(
        configuration: FBVideoStreamConfiguration,
        source: CaptureSource?,
        to consumer: any FBDataConsumer
    ) async throws -> any FBVideoStream {
        guard let source else {
            return try await createStream(configuration: configuration, to: consumer)
        }
        return try await createStream(
            configuration: configuration,
            displayPixelWidth: source.pixelWidth,
            displayPixelHeight: source.pixelHeight,
            sourceCrop: source.crop,
            to: consumer
        )
    }
}
