// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import SimUseVideo

// The FB*-tied capture entry points for the shared frame utilities.
// Everything else in `VideoFrameUtilities` is platform-neutral and lives
// in SimUseVideo; this extension is the one piece that must stay inside
// iOSSimBackend's FB* dep cone.
extension VideoFrameUtilities {
    public static func captureScreenshotData(from simulator: FBSimulator) async throws -> Data {
        let data = try await simulator.takeScreenshot(format: .png)
        guard !data.isEmpty else {
            throw VideoProcessingError.emptyScreenshot
        }
        return data
    }
}

/// A framebuffer-attached source of un-encoded frames.
///
/// `takeScreenshot` encodes on the simulator's behalf, which forces every
/// consumer into whatever container it picked — PNG — and makes a stream
/// that wants JPEG pay a decode plus a re-encode per frame. Reading the
/// framebuffer directly hands out the `CGImage` instead, so each sink
/// encodes exactly once into the container it needs, and the H.264
/// recorder never encodes to an intermediate container at all.
///
/// Attaching a consumer to the framebuffer costs a surface handshake, so
/// one source is created per capture session and reused for every frame.
public final class SimulatorFrameSource {
    private let image: FBSimulatorImage

    public init(simulator: FBSimulator) async throws {
        let framebuffer = try await simulator.connectToFramebuffer()
        self.image = FBSimulatorImage.image(with: framebuffer, logger: simulator.logger)
    }

    /// The framebuffer's current contents. Throws rather than returning
    /// nil so a frame loop can log and continue on a transient miss,
    /// matching how it already handles capture failures.
    public func currentFrame() throws -> CGImage {
        guard let frame = image.image() else {
            throw VideoProcessingError.emptyScreenshot
        }
        return frame
    }
}
