// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import AppKit
import CoreGraphics
import SimUseVideo

/// Unit coverage for the frame-processing utilities behind the streaming
/// formats and the screencap-based recording fallbacks — pure image
/// plumbing, no device needed.
@Suite("VideoFrameUtilities — frame processing")
struct VideoFrameProcessingTests {
    /// A solid-color PNG generated in-process, standing in for a
    /// screenshot / `screencap -p` frame.
    private func makePNG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let rep = NSBitmapImageRep(cgImage: image)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func makePatternPNG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))

        for y in 0..<height {
            for x in 0..<width {
                let red = CGFloat((x * 17 + y * 3) % 256) / 255.0
                let green = CGFloat((x * 5 + y * 11) % 256) / 255.0
                let blue = CGFloat((x * 13 + y * 7) % 256) / 255.0
                context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }

        let image = try #require(context.makeImage())
        let rep = NSBitmapImageRep(cgImage: image)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        try #require(VideoFrameUtilities.makeCGImage(from: try makePNG(width: width, height: height)))
    }

    private static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])
    private static let jpegMagic = Data([0xFF, 0xD8])

    @Test("makeCGImage decodes PNG data and rejects garbage")
    func makeCGImage() throws {
        let png = try makePNG(width: 64, height: 48)
        let image = try #require(VideoFrameUtilities.makeCGImage(from: png))
        #expect(image.width == 64)
        #expect(image.height == 48)

        #expect(VideoFrameUtilities.makeCGImage(from: Data("not an image".utf8)) == nil)
    }

    @Test("computeDimensions scales and rounds down to even")
    func computeDimensions() throws {
        let png = try makePNG(width: 101, height: 67)
        let image = try #require(VideoFrameUtilities.makeCGImage(from: png))

        let full = VideoFrameUtilities.computeDimensions(for: image, scale: 1.0)
        #expect(full.width == 100) // 101 rounded down to even
        #expect(full.height == 66)

        let half = VideoFrameUtilities.computeDimensions(for: image, scale: 0.5)
        #expect(half.width == 50)
        #expect(half.height == 32) // 33 rounded down to even
    }

    @Test("computeDimensions never collapses below 2x2")
    func computeDimensionsFloor() throws {
        let png = try makePNG(width: 4, height: 4)
        let image = try #require(VideoFrameUtilities.makeCGImage(from: png))
        let tiny = VideoFrameUtilities.computeDimensions(for: image, scale: 0.1)
        #expect(tiny.width >= 2)
        #expect(tiny.height >= 2)
    }

    // MARK: - encodeFrame: the single pass a captured frame pays

    @Test("encodeFrame writes the container it was asked for")
    func encodeFrameContainers() throws {
        let image = try makeImage(width: 64, height: 48)

        let png = try VideoFrameUtilities.encodeFrame(image, as: .png, scale: 1.0)
        #expect(png.starts(with: Self.pngMagic))

        let jpeg = try VideoFrameUtilities.encodeFrame(image, as: .jpeg(quality: 80), scale: 1.0)
        #expect(jpeg.starts(with: Self.jpegMagic))

        for data in [png, jpeg] {
            let decoded = try #require(VideoFrameUtilities.makeCGImage(from: data))
            #expect(decoded.width == 64)
            #expect(decoded.height == 48)
        }
    }

    @Test("encodeFrame honours JPEG quality")
    func encodeFrameQuality() throws {
        let image = try #require(VideoFrameUtilities.makeCGImage(from: try makePatternPNG(width: 128, height: 96)))
        let low = try VideoFrameUtilities.encodeFrame(image, as: .jpeg(quality: 20), scale: 1.0)
        let high = try VideoFrameUtilities.encodeFrame(image, as: .jpeg(quality: 90), scale: 1.0)
        #expect(low.count < high.count)
    }

    @Test("encodeFrame scales within the same pass, in either container")
    func encodeFrameScales() throws {
        let image = try makeImage(width: 100, height: 60)

        for container in [FrameContainer.png, .jpeg(quality: 80)] {
            let out = try VideoFrameUtilities.encodeFrame(image, as: container, scale: 0.5)
            let scaled = try #require(VideoFrameUtilities.makeCGImage(from: out))
            #expect(scaled.width == 50)
            #expect(scaled.height == 30)
        }
    }

    // MARK: - transcodeFrame: for captures that cannot pick their container

    @Test("transcodeFrame passes a matching lossless container through byte-for-byte")
    func transcodePassthrough() async throws {
        // The zero-transcode path: `screencap -p` already emits exactly what
        // the PNG-carrying formats want, so the bytes must not be touched.
        let png = try makePNG(width: 32, height: 32)
        let out = try VideoFrameUtilities.transcodeFrame(png, to: .png, scale: 1.0)
        #expect(out == png)
    }

    @Test("transcodeFrame encodes PNG input into JPEG when the sink needs JPEG")
    func transcodeToJPEG() throws {
        // Regression for MJPEG frames carrying PNG payloads under an
        // `image/jpeg` header at the default settings.
        let png = try makePNG(width: 32, height: 32)
        let out = try VideoFrameUtilities.transcodeFrame(png, to: .jpeg(quality: 80), scale: 1.0)
        #expect(out.starts(with: Self.jpegMagic))
        let decoded = try #require(VideoFrameUtilities.makeCGImage(from: out))
        #expect(decoded.width == 32)
        #expect(decoded.height == 32)
    }

    @Test("transcodeFrame never passes JPEG through, so --quality is always honoured")
    func transcodeAlwaysReencodesJPEG() throws {
        // JPEG bytes carry no record of the quality they were encoded at,
        // so a JPEG sink has to encode rather than trust the input.
        let image = try #require(VideoFrameUtilities.makeCGImage(from: try makePatternPNG(width: 128, height: 96)))
        let source = try VideoFrameUtilities.encodeFrame(image, as: .jpeg(quality: 95), scale: 1.0)

        let out = try VideoFrameUtilities.transcodeFrame(source, to: .jpeg(quality: 20), scale: 1.0)
        #expect(out != source)
        #expect(out.count < source.count)
    }

    @Test("transcodeFrame re-encodes a scaled frame back into its own container")
    func transcodeScales() throws {
        let png = try makePNG(width: 100, height: 60)
        let out = try VideoFrameUtilities.transcodeFrame(png, to: .png, scale: 0.5)
        #expect(out.starts(with: Self.pngMagic))
        let scaled = try #require(VideoFrameUtilities.makeCGImage(from: out))
        #expect(scaled.width == 50)
        #expect(scaled.height == 30)
    }

    @Test("mimeType matches the bytes each container actually produces")
    func mimeTypeMatchesPayload() throws {
        // The bug this contract exists to prevent: a frame header that
        // advertises a container the payload isn't.
        let image = try makeImage(width: 32, height: 32)

        for container in [FrameContainer.png, .jpeg(quality: 80)] {
            let data = try VideoFrameUtilities.encodeFrame(image, as: container, scale: 1.0)
            let expectedMagic = container == .png ? Self.pngMagic : Self.jpegMagic
            #expect(data.starts(with: expectedMagic), "\(container.mimeType) payload has the wrong magic bytes")
        }

        #expect(FrameContainer.png.mimeType == "image/png")
        #expect(FrameContainer.jpeg(quality: 80).mimeType == "image/jpeg")
    }

    @Test("estimateBitrate clamps to its floor and ceiling and grows with quality")
    func estimateBitrate() {
        // Tiny frame → floor.
        #expect(H264StreamRecorder.estimateBitrate(width: 16, height: 16, fps: 1, quality: 1) == 1_000_000)
        // Huge frame → ceiling.
        #expect(H264StreamRecorder.estimateBitrate(width: 10_000, height: 10_000, fps: 60, quality: 100) == 50_000_000)
        // Monotonic in quality between the clamps.
        let low = H264StreamRecorder.estimateBitrate(width: 1080, height: 2400, fps: 30, quality: 30)
        let high = H264StreamRecorder.estimateBitrate(width: 1080, height: 2400, fps: 30, quality: 90)
        #expect(low < high)
    }
}
