// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import AppKit
import CoreGraphics
import SimUseVideo

/// Unit coverage for the frame-processing utilities behind the JPEG
/// streaming formats and the screencap-based recording fallbacks —
/// pure image plumbing, no device needed.
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

    @Test("processJPEGData encodes default PNG input as JPEG")
    func processEncodesDefaultPNG() async throws {
        let png = try makePNG(width: 32, height: 32)
        let out = try await VideoFrameUtilities.processJPEGData(png, scale: 1.0, quality: 80)
        #expect(out.prefix(2) == Data([0xFF, 0xD8]))
        let encoded = try #require(VideoFrameUtilities.makeCGImage(from: out))
        #expect(encoded.width == 32)
        #expect(encoded.height == 32)
    }

    @Test("processJPEGData passes default JPEG input through untouched")
    func processPassesThroughDefaultJPEG() async throws {
        let png = try makePNG(width: 32, height: 32)
        let jpeg = try await VideoFrameUtilities.processJPEGData(png, scale: 1.0, quality: 90)
        let out = try await VideoFrameUtilities.processJPEGData(jpeg, scale: 1.0, quality: 80)
        #expect(out == jpeg)
    }

    @Test("non-default quality re-encodes to JPEG")
    func processReencodesQuality() async throws {
        let png = try makePNG(width: 64, height: 64)
        let out = try await VideoFrameUtilities.processJPEGData(png, scale: 1.0, quality: 50)
        #expect(out != png)
        #expect(out.prefix(2) == Data([0xFF, 0xD8]))
        let reencoded = try #require(VideoFrameUtilities.makeCGImage(from: out))
        #expect(reencoded.width == 64)
        #expect(reencoded.height == 64)
    }

    @Test("JPEG quality changes encoded output size")
    func processAppliesQuality() async throws {
        let png = try makePatternPNG(width: 128, height: 96)
        let low = try await VideoFrameUtilities.processJPEGData(png, scale: 1.0, quality: 20)
        let high = try await VideoFrameUtilities.processJPEGData(png, scale: 1.0, quality: 90)

        #expect(low != high)
        #expect(low.count < high.count)
    }

    @Test("scaling re-encodes to JPEG at the requested pixel dimensions")
    func processScales() async throws {
        let png = try makePNG(width: 100, height: 60)
        let out = try await VideoFrameUtilities.processJPEGData(png, scale: 0.5, quality: 80)
        #expect(out.prefix(2) == Data([0xFF, 0xD8]))
        let scaled = try #require(VideoFrameUtilities.makeCGImage(from: out))
        #expect(scaled.width == 50)
        #expect(scaled.height == 30)
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
