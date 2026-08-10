// SPDX-License-Identifier: Apache-2.0
import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import os
import SimUseCore

/// Stop-path watchdog for the `record-video` command.
///
/// After a stop signal arrives, the frame loop breaks and
/// `H264StreamRecorder.finish()` (`AVAssetWriter.finishWriting`) writes the
/// mp4 trailer (moov atom). If finalization hangs past `gracePeriod`, the
/// process must not exit 0 — the file is likely truncated and unplayable —
/// so the watchdog warns on stderr and exits `EX_SOFTWARE` instead of
/// leaving a supervisor to SIGKILL us or, worse, reporting success.
public enum RecordingFinishWatchdog {
    /// Grace window granted to `finish()` after the stop signal. Wide
    /// enough for a normal trailer flush (typically well under 1 s) while
    /// still bounding a hung `finishWriting`.
    public static let gracePeriod: TimeInterval = 3.0

    /// `EX_SOFTWARE` (sysexits.h). Distinct from the exit codes the CLI
    /// already produces: 0 (success), 1 (runtime error), 64 (usage error).
    public static let exitCode: Int32 = 70

    public static let warningMessage =
        "warning: video finalization did not complete within \(Int(gracePeriod))s — output file may be truncated or unplayable\n"

    /// Arm the watchdog from the signal handler. `recordingFinished` must
    /// be cancelled once `finish()` has returned (success or failure).
    public static func arm(recordingFinished: CancellationFlag) {
        DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod) {
            if !recordingFinished.isCancelled() {
                FileHandle.standardError.write(Data(warningMessage.utf8))
                _exit(exitCode)
            }
        }
    }
}

public enum VideoProcessingError: Error {
    case emptyScreenshot
    case failedToDecodeImage
    case failedToEncodeImage
    case failedToAllocatePixelBuffer
}

/// Thrown when the asset writer input refuses new frames for longer
/// than the stall timeout. A wedged writer (disk pressure, encoder
/// failure) does not recover, so callers must abort the recording
/// rather than retry — a distinct type lets frame loops tell this
/// fatal condition apart from transient per-frame capture errors.
public struct VideoWriterStallError: Error, LocalizedError, Equatable {
    public let timeout: TimeInterval

    public var errorDescription: String? {
        String(
            format: "Video writer did not accept new frames for %.0f seconds; the writer appears stalled (disk pressure or encoder failure). Aborting recording.",
            timeout
        )
    }
}

public struct VideoFrameUtilities {
    public static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public static func processJPEGData(_ data: Data, scale: Double, quality: Int) async throws -> Data {
        if scale < 1.0 {
            return try await scaleJPEGData(data, scale: scale, quality: quality)
        } else if quality != 80 || !isJPEG(data) {
            return try await reencodeJPEGData(data, quality: quality)
        }
        return data
    }

    private static func isJPEG(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(source) as String? else {
            return false
        }
        return UTType(typeIdentifier)?.conforms(to: .jpeg) == true
    }

    public static func computeDimensions(for image: CGImage, scale: Double) -> (width: Int, height: Int) {
        let scaledWidth = max(2, Int(Double(image.width) * scale))
        let scaledHeight = max(2, Int(Double(image.height) * scale))
        let evenWidth = scaledWidth - (scaledWidth % 2)
        let evenHeight = scaledHeight - (scaledHeight % 2)
        return (max(evenWidth, 2), max(evenHeight, 2))
    }

    private static func encodeJPEG(_ image: CGImage, quality: Int) throws -> Data {
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  data,
                  "public.jpeg" as CFString,
                  1,
                  nil
              ) else {
            throw VideoProcessingError.failedToEncodeImage
        }

        let properties = [
            kCGImageDestinationLossyCompressionQuality: Double(quality) / 100.0
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)

        guard CGImageDestinationFinalize(destination) else {
            throw VideoProcessingError.failedToEncodeImage
        }

        return data as Data
    }

    private static func scaleJPEGData(_ data: Data, scale: Double, quality: Int) async throws -> Data {
        guard let image = makeCGImage(from: data) else {
            throw VideoProcessingError.failedToDecodeImage
        }

        let dimensions = computeDimensions(for: image, scale: scale)
        guard let context = CGContext(
            data: nil,
            width: dimensions.width,
            height: dimensions.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw VideoProcessingError.failedToAllocatePixelBuffer
        }

        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(dimensions.width),
                height: CGFloat(dimensions.height)
            )
        )

        guard let scaledImage = context.makeImage() else {
            throw VideoProcessingError.failedToEncodeImage
        }

        return try encodeJPEG(scaledImage, quality: quality)
    }

    private static func reencodeJPEGData(_ data: Data, quality: Int) async throws -> Data {
        guard let image = makeCGImage(from: data) else {
            throw VideoProcessingError.failedToDecodeImage
        }

        return try encodeJPEG(image, quality: quality)
    }
}

public final class H264StreamRecorder: Sendable {
    /// The non-Sendable AVFoundation objects, confined to the lock.
    private struct State {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
    }
    private let state: OSAllocatedUnfairLock<State>
    private let width: Int
    private let height: Int

    public init(outputURL: URL, width: Int, height: Int, fps: Int, quality: Int) throws {
        self.width = width
        self.height = height

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: Self.estimateBitrate(width: width, height: height, fps: fps, quality: quality),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]

        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.canAdd(input) else {
            throw CLIError(errorDescription: "Unable to configure video writer input")
        }
        writer.add(input)

        if !writer.startWriting() {
            throw CLIError(errorDescription: "Failed to start asset writer: \(writer.error?.localizedDescription ?? "Unknown error")")
        }
        writer.startSession(atSourceTime: .zero)

        self.state = OSAllocatedUnfairLock(initialState: State(writer: writer, input: input, adaptor: adaptor))
    }

    /// How long `append` waits for the writer input to drain before
    /// giving up. Generous on purpose: with `expectsMediaDataInRealTime`
    /// a healthy writer is ready again within milliseconds, so reaching
    /// this deadline means the writer is wedged, not merely busy.
    static let readinessTimeout: TimeInterval = 10

    /// Poll `isReady` every `pollInterval` until it returns true,
    /// throwing `VideoWriterStallError` once `timeout` has elapsed.
    /// The clock and sleep hooks are injectable so the timeout policy
    /// is unit-testable without AVFoundation or real sleeping.
    static func waitUntilReady(
        isReady: () -> Bool,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.005,
        now: () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws {
        let deadline = now().advanced(by: .seconds(timeout))
        while !isReady() {
            guard now() < deadline else {
                throw VideoWriterStallError(timeout: timeout)
            }
            sleep(pollInterval)
        }
    }

    public func append(image: CGImage, presentationTime: CMTime) throws {
        try state.withLock { state in
            try Self.waitUntilReady(
                isReady: { state.input.isReadyForMoreMediaData },
                timeout: Self.readinessTimeout
            )

            guard let pixelBuffer = Self.makePixelBuffer(width: width, height: height, adaptor: state.adaptor) else {
                throw VideoProcessingError.failedToAllocatePixelBuffer
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                throw CLIError(errorDescription: "Failed to create drawing context")
            }

            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: CGFloat(height), width: CGFloat(width), height: -CGFloat(height)))

            guard state.adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw CLIError(errorDescription: "Failed to append frame: \(state.writer.error?.localizedDescription ?? "Unknown error")")
            }
        }
    }

    public func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            state.withLock { state in
                state.input.markAsFinished()
                state.writer.finishWriting {
                    let error = self.state.withLock { $0.writer.error }
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
        }
    }

    public func invalidate() {
        state.withLock { state in
            if state.writer.status == .writing {
                state.input.markAsFinished()
                state.writer.cancelWriting()
            }
        }
    }

    private static func makePixelBuffer(width: Int, height: Int, adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard status == kCVReturnSuccess else {
                return nil
            }
        } else {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
            guard status == kCVReturnSuccess else {
                return nil
            }
        }
        return pixelBuffer
    }

    public static func estimateBitrate(width: Int, height: Int, fps: Int, quality: Int) -> Int {
        let qualityFactor = max(0.1, min(Double(quality) / 100.0, 1.0))
        let bitsPerPixel = 0.1 + (0.4 * qualityFactor)
        let bitrate = Double(width * height) * bitsPerPixel * Double(fps)
        return min(max(Int(bitrate), 1_000_000), 50_000_000)
    }
}
