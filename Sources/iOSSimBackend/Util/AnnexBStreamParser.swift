// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A single H.264 NAL unit: the 1-byte header plus its EBSP payload,
/// with the Annex-B start code already stripped.
public struct H264NALUnit: Equatable {
    /// `nal_unit_type` — the low 5 bits of the header byte.
    public let type: UInt8
    /// Header byte + payload, no start code, emulation-prevention bytes intact.
    public let data: Data

    public init(type: UInt8, data: Data) {
        self.type = type
        self.data = data
    }

    /// VCL NAL unit types (1...5) carry coded slice data; everything else
    /// (SPS/PPS/SEI/AUD/…) is non-VCL.
    public var isVCL: Bool { type >= 1 && type <= 5 }
}

/// One access unit (a single coded picture) in decode order. SPS/PPS and
/// AUD NAL units are stripped out during assembly — parameter sets go into
/// the mp4 `avcC` box, and AUDs are only boundary hints.
public struct H264AccessUnit: Equatable {
    public let nalUnits: [H264NALUnit]
    /// True when the AU contains an IDR slice (NAL type 5) — the mp4 muxer
    /// marks these as sync samples.
    public let isIDR: Bool

    public init(nalUnits: [H264NALUnit], isIDR: Bool) {
        self.nalUnits = nalUnits
        self.isIDR = isIDR
    }
}

/// Incremental Annex-B byte-stream parser. Feed arbitrary chunks (as they
/// arrive from `FBSimulatorVideoStream` or `adb screenrecord`) and receive
/// complete access units. Start codes may straddle chunk boundaries; a NAL
/// unit is only emitted once the *next* start code confirms its end.
public final class AnnexBStreamParser {
    /// Latest SPS (NAL type 7), stripped of its start code.
    public private(set) var currentSPS: Data?
    /// Latest PPS (NAL type 8), stripped of its start code.
    public private(set) var currentPPS: Data?

    /// Bytes seen but not yet split into a complete NAL unit. Always begins
    /// at the most recent start code (or is empty), so it never outgrows one
    /// in-flight NAL unit.
    private var buffer = Data()

    /// NAL units accumulated for the access unit currently being assembled.
    private var pending: [H264NALUnit] = []
    private var pendingHasVCL = false
    private var pendingIsIDR = false

    /// Access units completed during the in-progress `consume(_:)` call.
    private var completed: [H264AccessUnit] = []

    public init() {}

    /// Feed a chunk; returns every access unit that became complete as a
    /// result (possibly none).
    public func consume(_ data: Data) -> [H264AccessUnit] {
        buffer.append(data)
        for nalu in extractNALUnits() {
            route(nalu)
        }
        defer { completed.removeAll(keepingCapacity: true) }
        return completed
    }

    /// End-of-stream flush: drain the final NAL unit (which has no following
    /// start code to terminate it) and close the trailing access unit. This
    /// can emit up to two units — draining the last NAL unit may first close
    /// the previous picture before the final one is closed. Safe to call more
    /// than once (returns empty after the first).
    public func flush() -> [H264AccessUnit] {
        for nalu in drainFinalNALUnit() {
            route(nalu)
        }
        closePendingAU()
        defer { completed.removeAll(keepingCapacity: true) }
        return completed
    }

    // MARK: - NAL unit routing / AU assembly

    /// H.264 access-unit boundary rule (simplified for non-reordered,
    /// in-order streams from our two capture sources): a new AU begins at
    /// the first VCL slice with `first_mb_in_slice == 0`, or at any leading
    /// non-VCL unit (AUD/SPS/PPS/SEI) that follows a VCL unit.
    private func route(_ nalu: H264NALUnit) {
        if nalu.isVCL {
            let firstMB = Self.firstMBInSlice(nalu.data) ?? 0
            if firstMB == 0 && pendingHasVCL {
                closePendingAU()
            }
            pending.append(nalu)
            pendingHasVCL = true
            if nalu.type == 5 { pendingIsIDR = true }
            return
        }

        // Non-VCL unit after a VCL means the previous picture is done.
        if pendingHasVCL {
            closePendingAU()
        }
        switch nalu.type {
        case 7: currentSPS = nalu.data
        case 8: currentPPS = nalu.data
        case 9: break // AUD: boundary hint only, not carried into the AU
        default: pending.append(nalu) // SEI and friends lead the next AU
        }
    }

    private func closePendingAU() {
        defer {
            pending.removeAll(keepingCapacity: true)
            pendingHasVCL = false
            pendingIsIDR = false
        }
        guard pendingHasVCL else { return }
        completed.append(H264AccessUnit(nalUnits: pending, isIDR: pendingIsIDR))
    }

    // MARK: - Start-code splitting

    /// Split `buffer` into complete NAL units, leaving the trailing
    /// (not-yet-terminated) unit in `buffer` for the next chunk.
    private func extractNALUnits() -> [H264NALUnit] {
        let bytes = [UInt8](buffer)
        let starts = Self.startCodeOffsets(bytes)
        guard !starts.isEmpty else { return [] }

        var nalus: [H264NALUnit] = []
        for index in starts.indices {
            let payloadStart = starts[index] + 3
            // The last start code has no terminator yet — keep it buffered.
            guard index + 1 < starts.count else { break }
            if let nalu = Self.makeNALUnit(bytes, payloadStart: payloadStart, rawEnd: starts[index + 1]) {
                nalus.append(nalu)
            }
        }

        buffer = Data(bytes[starts[starts.count - 1]...])
        return nalus
    }

    /// EOF variant: the final start code's NAL unit runs to the end of the
    /// buffer with no terminating start code.
    private func drainFinalNALUnit() -> [H264NALUnit] {
        let bytes = [UInt8](buffer)
        let starts = Self.startCodeOffsets(bytes)
        guard let last = starts.last else { return [] }
        buffer.removeAll(keepingCapacity: false)
        guard let nalu = Self.makeNALUnit(bytes, payloadStart: last + 3, rawEnd: bytes.count) else {
            return []
        }
        return [nalu]
    }

    /// Offsets of every 3-byte `00 00 01` start-code prefix. A 4-byte
    /// `00 00 00 01` is found as its trailing 3 bytes; the extra leading
    /// zero is trimmed as a trailing byte of the preceding unit. Emulation
    /// prevention guarantees `00 00 01` never appears inside a NAL payload.
    static func startCodeOffsets(_ bytes: [UInt8]) -> [Int] {
        var offsets: [Int] = []
        guard bytes.count >= 3 else { return offsets }
        var i = 0
        while i <= bytes.count - 3 {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                offsets.append(i)
                i += 3
            } else {
                i += 1
            }
        }
        return offsets
    }

    private static func makeNALUnit(_ bytes: [UInt8], payloadStart: Int, rawEnd: Int) -> H264NALUnit? {
        var end = rawEnd
        // Trim trailing zeros: they belong to the next start code
        // (`00 00 00 01`) or are cabac_zero_word / trailing_zero_8bits.
        while end > payloadStart && bytes[end - 1] == 0 { end -= 1 }
        guard end > payloadStart else { return nil }
        let slice = bytes[payloadStart..<end]
        guard let header = slice.first else { return nil }
        return H264NALUnit(type: header & 0x1F, data: Data(slice))
    }

    // MARK: - Slice header decoding

    /// Read `first_mb_in_slice` — the first `ue(v)` field of the slice
    /// header, immediately after the 1-byte NAL header. Returns nil if the
    /// unit is too short to decode.
    static func firstMBInSlice(_ nalu: Data) -> UInt? {
        guard nalu.count > 1 else { return nil }
        let rbsp = deEscape(Array(nalu.dropFirst()), maxBytes: 8)
        var reader = BitReader(rbsp)
        return reader.readUnsignedExpGolomb()
    }

    /// Remove emulation-prevention bytes (`00 00 03` → `00 00`) from the
    /// leading `maxBytes` of an EBSP so the slice header can be bit-read.
    static func deEscape(_ bytes: [UInt8], maxBytes: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(min(bytes.count, maxBytes))
        var zeroRun = 0
        for byte in bytes {
            if zeroRun >= 2 && byte == 0x03 {
                zeroRun = 0
                continue
            }
            out.append(byte)
            zeroRun = (byte == 0) ? zeroRun + 1 : 0
            if out.count >= maxBytes { break }
        }
        return out
    }
}

/// Minimal MSB-first bit reader over a de-escaped RBSP byte array.
struct BitReader {
    private let bytes: [UInt8]
    private var bitPos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func readBit() -> UInt8? {
        let byteIndex = bitPos >> 3
        guard byteIndex < bytes.count else { return nil }
        let bit = (bytes[byteIndex] >> (7 - (bitPos & 7))) & 1
        bitPos += 1
        return bit
    }

    /// Decode an unsigned Exp-Golomb `ue(v)` code.
    mutating func readUnsignedExpGolomb() -> UInt? {
        var leadingZeros = 0
        while true {
            guard let bit = readBit() else { return nil }
            if bit == 1 { break }
            leadingZeros += 1
            if leadingZeros > 31 { return nil }
        }
        guard leadingZeros > 0 else { return 0 }
        var suffix: UInt = 0
        for _ in 0..<leadingZeros {
            guard let bit = readBit() else { return nil }
            suffix = (suffix << 1) | UInt(bit)
        }
        return (UInt(1) << leadingZeros) - 1 + suffix
    }
}
