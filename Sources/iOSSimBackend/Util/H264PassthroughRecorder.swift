// SPDX-License-Identifier: Apache-2.0
import Foundation
import AVFoundation
import CoreMedia
import SimUseCore

public enum H264PassthroughError: Error, LocalizedError, Equatable {
    /// The recording was finalized without a single decodable frame.
    case noFramesCaptured
    /// SPS/PPS could not be turned into a CMFormatDescription.
    case missingParameterSets
    /// A later stream segment reported different display dimensions
    /// (e.g. a rotation) than the first — passthrough can't splice these.
    case dimensionsChanged(old: String, new: String)
    case appendFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noFramesCaptured:
            return "No video frames were captured (static screen or the stream never produced a keyframe)."
        case .missingParameterSets:
            return "H.264 parameter sets (SPS/PPS) were missing or malformed."
        case let .dimensionsChanged(old, new):
            return "Display size changed mid-recording (\(old) → \(new)); recording stopped."
        case let .appendFailed(detail):
            return "Failed to append video sample: \(detail)"
        }
    }
}

/// Muxes an already-encoded H.264 elementary stream into an MP4 without
/// re-encoding. Access units (from `AnnexBStreamParser`) are rewrapped as
/// AVCC-framed `CMSampleBuffer`s and appended to a passthrough
/// `AVAssetWriterInput`. Presentation timestamps come from the host arrival
/// clock, since neither capture source embeds timing.
public final class H264PassthroughRecorder: @unchecked Sendable {
    private let outputURL: URL
    private let writer: AVAssetWriter
    /// When set, timestamps are laid out as a constant frame rate
    /// (`frameIndex / frameRate`) instead of derived from host arrival time.
    /// This removes the byte-arrival jitter of an eager fixed-rate stream;
    /// nil keeps the variable-rate host-clock behavior (Android screenrecord).
    private let frameRate: Int?
    private var input: AVAssetWriterInput?

    private var formatDescription: CMFormatDescription?
    private var formatSPS: Data?
    private var formatPPS: Data?
    private var formatDimensions: CMVideoDimensions?

    private var firstHostTime: TimeInterval?
    private var lastPTS: CMTime = .invalid

    public private(set) var framesAppended: Int64 = 0

    public init(outputURL: URL, frameRate: Int? = nil) throws {
        self.outputURL = outputURL
        self.frameRate = frameRate
        self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    }

    /// Append one access unit. The first call lazily builds the format
    /// description and starts the writer session (parameter sets are only
    /// known once the first SPS/PPS arrive).
    public func append(accessUnit: H264AccessUnit, sps: Data, pps: Data, hostTime: TimeInterval) throws {
        try ensureStarted(sps: sps, pps: pps, hostTime: hostTime)
        guard let input, let formatDescription, let firstHostTime else {
            throw H264PassthroughError.appendFailed("writer not initialized")
        }

        try H264StreamRecorder.waitUntilReady(
            isReady: { input.isReadyForMoreMediaData },
            timeout: H264StreamRecorder.readinessTimeout
        )

        let pts: CMTime
        if let frameRate {
            pts = CMTime(value: framesAppended, timescale: CMTimeScale(frameRate))
        } else {
            pts = Self.normalizedPTS(hostTime: hostTime, firstHostTime: firstHostTime, lastPTS: lastPTS)
        }
        let sampleBuffer = try Self.makeSampleBuffer(
            avcc: Self.avccData(for: accessUnit),
            formatDescription: formatDescription,
            pts: pts,
            isIDR: accessUnit.isIDR
        )
        guard input.append(sampleBuffer) else {
            throw H264PassthroughError.appendFailed(writer.error?.localizedDescription ?? "unknown writer error")
        }
        lastPTS = pts
        framesAppended += 1
    }

    /// Finalize the MP4. `stopHostTime` sets the session end so the final
    /// (variable-rate) frame is held for its true wall-clock duration.
    /// Throws `.noFramesCaptured` — after deleting the empty output — when
    /// no frame was ever appended.
    public func finish(stopHostTime: TimeInterval?) async throws {
        guard let input, framesAppended > 0, let firstHostTime else {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: outputURL)
            throw H264PassthroughError.noFramesCaptured
        }

        if let frameRate {
            // Hold the last frame for one frame interval past its PTS.
            writer.endSession(atSourceTime: CMTime(value: framesAppended, timescale: CMTimeScale(frameRate)))
        } else if let stopHostTime {
            let endPTS = Self.normalizedPTS(hostTime: stopHostTime, firstHostTime: firstHostTime, lastPTS: lastPTS)
            writer.endSession(atSourceTime: endPTS)
        }
        input.markAsFinished()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if let error = self.writer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    public func invalidate() {
        if writer.status == .writing {
            input?.markAsFinished()
            writer.cancelWriting()
        }
    }

    // MARK: - Startup / segment handling

    private func ensureStarted(sps: Data, pps: Data, hostTime: TimeInterval) throws {
        guard input == nil else {
            // Already recording: only react if the parameter sets changed
            // (new segment on Android's 180 s restart, or a rotation).
            guard sps != formatSPS || pps != formatPPS else { return }
            let newFormat = try Self.makeFormatDescription(sps: sps, pps: pps)
            let newDimensions = CMVideoFormatDescriptionGetDimensions(newFormat)
            if let old = formatDimensions, old.width != newDimensions.width || old.height != newDimensions.height {
                throw H264PassthroughError.dimensionsChanged(
                    old: "\(old.width)x\(old.height)",
                    new: "\(newDimensions.width)x\(newDimensions.height)"
                )
            }
            FileHandle.standardError.write(Data("note: stream parameter sets changed mid-recording (same size); continuing\n".utf8))
            formatDescription = newFormat
            formatSPS = sps
            formatPPS = pps
            return
        }

        let format = try Self.makeFormatDescription(sps: sps, pps: pps)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        writerInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(writerInput) else {
            throw H264PassthroughError.appendFailed("writer cannot add passthrough input")
        }
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw H264PassthroughError.appendFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        input = writerInput
        formatDescription = format
        formatSPS = sps
        formatPPS = pps
        formatDimensions = CMVideoFormatDescriptionGetDimensions(format)
        firstHostTime = hostTime
    }

    // MARK: - Pure helpers (unit-tested)

    /// Concatenate an access unit's NAL units in AVCC framing: each prefixed
    /// with its 4-byte big-endian length (matching `nalUnitHeaderLength: 4`).
    static func avccData(for accessUnit: H264AccessUnit) -> Data {
        var out = Data()
        for nalu in accessUnit.nalUnits {
            var length = UInt32(nalu.data.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(nalu.data)
        }
        return out
    }

    /// Map a host arrival time to a monotonic PTS on a 600 timescale. The
    /// first frame is pinned to zero (the session start); any non-increasing
    /// value is bumped one tick past the previous PTS, since passthrough
    /// inputs reject out-of-order timestamps.
    static func normalizedPTS(hostTime: TimeInterval, firstHostTime: TimeInterval, lastPTS: CMTime) -> CMTime {
        let seconds = max(0, hostTime - firstHostTime)
        var pts = CMTime(seconds: seconds, preferredTimescale: 600)
        if lastPTS.isValid, pts <= lastPTS {
            pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 600))
        }
        return pts
    }

    static func makeFormatDescription(sps: Data, pps: Data) throws -> CMFormatDescription {
        guard !sps.isEmpty, !pps.isEmpty else {
            throw H264PassthroughError.missingParameterSets
        }
        var format: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard
                    let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                    let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress
                else { return -1 }
                let pointers = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format
                        )
                    }
                }
            }
        }
        guard status == noErr, let format else {
            throw H264PassthroughError.missingParameterSets
        }
        return format
    }

    private static func makeSampleBuffer(
        avcc: Data,
        formatDescription: CMFormatDescription,
        pts: CMTime,
        isIDR: Bool
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw H264PassthroughError.appendFailed("CMBlockBuffer create failed (\(blockStatus))")
        }
        let copyStatus = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw H264PassthroughError.appendFailed("CMBlockBuffer copy failed (\(copyStatus))")
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = avcc.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw H264PassthroughError.appendFailed("CMSampleBuffer create failed (\(sampleStatus))")
        }

        // A sample is a sync sample unless flagged otherwise; only non-IDR
        // pictures need the NotSync attachment so seeking lands on keyframes.
        if !isIDR,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        return sampleBuffer
    }
}
