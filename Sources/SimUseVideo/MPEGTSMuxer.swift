// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Wraps H.264 access units in an MPEG-2 transport stream.
///
/// Exists because Annex B carries no timing. A player fed a bare elementary
/// stream has to assume a frame rate — ffmpeg assumes 25 fps — and when the
/// source runs faster it drains slower than it fills, so the lag grows
/// without bound instead of settling. MPEG-TS carries a PTS per access unit
/// on the standard 90 kHz clock, which is what lets a player pace off the
/// stream.
///
/// Transport stream rather than fragmented MP4 on purpose: fMP4 wants to cut
/// fragments on keyframe boundaries, and `adb screenrecord` emits keyframes
/// too rarely to give a live preview timely fragments. A transport stream has
/// no such constraint — every PES packet stands on its own — which is why it
/// is the format broadcast and HLS use.
///
/// Deliberately minimal: one program, one video elementary stream, no audio,
/// and the PCR riding the video PID's adaptation field. That is all a viewer
/// needs, and every field below is fixed by ISO/IEC 13818-1.
public struct MPEGTSMuxer {
    /// Fixed by the standard: 188-byte packets with a 4-byte header.
    static let packetSize = 188
    static let payloadSize = packetSize - 4

    static let syncByte: UInt8 = 0x47
    static let patPID: UInt16 = 0x0000
    static let pmtPID: UInt16 = 0x1000
    static let videoPID: UInt16 = 0x0100
    /// ISO/IEC 14496-10 (H.264) elementary stream.
    static let h264StreamType: UInt8 = 0x1B
    /// PES stream_id for the first video stream.
    static let videoStreamID: UInt8 = 0xE0
    /// MPEG-TS timestamps run on a 90 kHz clock.
    static let timescale: Double = 90_000

    /// How far a picture's PTS leads the clock delivered alongside it.
    ///
    /// A receiver starts its clock from the PCR and presents a picture when
    /// that clock reaches the picture's PTS. With PTS equal to PCR the
    /// picture is due the instant it arrives, leaving no time to decode it —
    /// ffmpeg reports every such picture as `Packet corrupt`. 100 ms is the
    /// usual small decode allowance and costs nothing on a live preview: it
    /// shifts the whole timeline by a constant, not per picture.
    static let decodeLead: Double = 0.1

    /// Continuity counters are per-PID and wrap at 16; a decoder uses them to
    /// detect dropped packets, so they have to advance exactly once per
    /// packet emitted on that PID.
    private var patContinuity: UInt8 = 0
    private var pmtContinuity: UInt8 = 0
    private var videoContinuity: UInt8 = 0

    public init() {}

    /// A packet on the video PID carrying only an adaptation field with the
    /// PCR — no payload.
    ///
    /// Nothing emits these today. It is the standards-shaped way to keep the
    /// clock advancing while a variable-frame-rate source sends no pictures,
    /// and that design was implemented and measured against the alternative
    /// the stream writer ships — see `MPEGTSStreamWriter.maxFrameGap` for why
    /// it lost. Kept because it is the right primitive for anyone revisiting
    /// that trade-off with a different consumer in mind.
    public mutating func clockReference(at seconds: TimeInterval) -> Data {
        let ticks = UInt64(max(0, seconds) * Self.timescale)
        var packet = Data(capacity: Self.packetSize)
        packet.append(Self.syncByte)
        packet.append(UInt8((Self.videoPID >> 8) & 0x1F))
        packet.append(UInt8(Self.videoPID & 0xFF))
        // adaptation_field_control = 0b10: adaptation field, no payload.
        // The continuity counter deliberately does not advance — a receiver
        // uses it to detect loss, and the standard only counts packets that
        // carry payload, so burning a number here would make it report drops
        // that never happened.
        packet.append(0x20 | (videoContinuity & 0x0F))

        // The whole 184-byte body is the adaptation field.
        var field = Self.adaptationField(isIDR: false, pcr: ticks)
        field = Self.stuffedAdaptationField(existing: field, targetLength: Self.payloadSize)
        packet.append(field)
        assert(packet.count == Self.packetSize, "PCR packet must be 188 bytes, got \(packet.count)")
        return packet
    }

    /// Program tables, which a player needs before it can interpret any
    /// elementary stream. Re-emitted periodically so a consumer that joins
    /// mid-stream can start decoding.
    public mutating func programTables() -> Data {
        var out = Data()
        out.append(packetize(payload: Self.patPayload(), pid: Self.patPID, continuity: &patContinuity, isStart: true))
        out.append(packetize(payload: Self.pmtPayload(), pid: Self.pmtPID, continuity: &pmtContinuity, isStart: true))
        return out
    }

    /// One access unit as a PES packet split across TS packets.
    ///
    /// - Parameters:
    ///   - annexB: the access unit in Annex B framing (start codes intact).
    ///   - pts: presentation time in seconds from the start of the stream.
    ///   - isIDR: whether this unit is a random-access point, which sets the
    ///     adaptation field's random-access indicator.
    ///   - discontinuity: set when the timeline jumped rather than advanced
    ///     — the clock this picture arrives against is not continuous with
    ///     the previous one. Declaring it is what makes a compacted timeline
    ///     legitimate instead of merely a broken clock: a receiver that
    ///     disciplines its own clock from the PCR resynchronises rather than
    ///     treating the picture as wildly late.
    public mutating func packets(
        annexB: Data,
        pts: TimeInterval,
        isIDR: Bool,
        discontinuity: Bool = false
    ) -> Data {
        let ticks = UInt64((max(0, pts) + Self.decodeLead) * Self.timescale)
        // The clock trails the presentation time by the decode allowance.
        let pcrTicks = UInt64(max(0, pts) * Self.timescale)
        var pes = Self.pesHeader(payloadSize: annexB.count, pts: ticks)
        pes.append(annexB)

        var out = Data()
        var offset = 0
        var isFirst = true
        while offset < pes.count {
            // Every access unit carries the PCR, not just keyframes: a
            // player builds its clock from the PCR and the standard wants
            // one at least every 100 ms, so emitting it per keyframe only
            // — `screenrecord` sends those rarely — leaves ffplay without a
            // clock and it never starts presenting.
            let adaptation: Data? = isFirst
                ? Self.adaptationField(isIDR: isIDR, pcr: pcrTicks, discontinuity: discontinuity)
                : nil
            let capacity = Self.payloadSize - (adaptation?.count ?? 0)
            let chunk = pes[pes.index(pes.startIndex, offsetBy: offset)..<pes.index(pes.startIndex, offsetBy: min(offset + capacity, pes.count))]
            out.append(
                packetize(
                    payload: Data(chunk),
                    pid: Self.videoPID,
                    continuity: &videoContinuity,
                    isStart: isFirst,
                    adaptation: adaptation
                )
            )
            offset += chunk.count
            isFirst = false
        }
        return out
    }

    // MARK: - Packet assembly

    /// Wrap up to one packet's worth of payload in a TS header, padding with
    /// an adaptation field when the payload falls short of 184 bytes (TS
    /// packets are fixed-size, so a short tail must be stuffed).
    private func packetize(
        payload: Data,
        pid: UInt16,
        continuity: inout UInt8,
        isStart: Bool,
        adaptation: Data? = nil
    ) -> Data {
        var adaptationField = adaptation ?? Data()
        if payload.count + adaptationField.count < Self.payloadSize {
            adaptationField = Self.stuffedAdaptationField(
                existing: adaptationField,
                targetLength: Self.payloadSize - payload.count
            )
        }

        var packet = Data(capacity: Self.packetSize)
        packet.append(Self.syncByte)
        // transport_error_indicator(0) | payload_unit_start_indicator |
        // transport_priority(0) | PID high 5 bits
        packet.append(UInt8((isStart ? 0x40 : 0x00) | Int((pid >> 8) & 0x1F)))
        packet.append(UInt8(pid & 0xFF))
        // scrambling(00) | adaptation_field_control | continuity_counter
        let adaptationControl: UInt8 = adaptationField.isEmpty ? 0x10 : 0x30
        packet.append(adaptationControl | (continuity & 0x0F))
        continuity = (continuity &+ 1) & 0x0F

        packet.append(adaptationField)
        packet.append(payload)
        assert(packet.count == Self.packetSize, "TS packet must be exactly 188 bytes, got \(packet.count)")
        return packet
    }

    /// Adaptation field carrying the discontinuity and random-access
    /// indicators plus the program clock reference.
    static func adaptationField(isIDR: Bool, pcr: UInt64?, discontinuity: Bool = false) -> Data {
        var flags: UInt8 = 0
        if discontinuity { flags |= 0x80 }  // discontinuity_indicator
        if isIDR { flags |= 0x40 }          // random_access_indicator
        if pcr != nil { flags |= 0x10 }     // PCR_flag

        var field = Data([flags])
        if let pcr {
            // PCR is 33 bits of 90 kHz base, 6 reserved bits, 9 bits of a
            // 27 MHz extension we leave at zero.
            let base = pcr & 0x1_FFFF_FFFF
            field.append(UInt8((base >> 25) & 0xFF))
            field.append(UInt8((base >> 17) & 0xFF))
            field.append(UInt8((base >> 9) & 0xFF))
            field.append(UInt8((base >> 1) & 0xFF))
            field.append(UInt8(((base & 0x1) << 7) | 0x7E))
            field.append(0x00)
        }
        // Prefix with the length byte (the field's own length, excluding it).
        return Data([UInt8(field.count)]) + field
    }

    /// Grow an adaptation field with stuffing bytes so payload + field lands
    /// exactly on 184 bytes.
    static func stuffedAdaptationField(existing: Data, targetLength: Int) -> Data {
        precondition(targetLength >= 1, "cannot stuff into \(targetLength) bytes")
        if targetLength == 1 {
            // No room for flags: a length of zero is the standard way to
            // spend exactly one byte.
            return Data([0x00])
        }
        // existing is [length][flags][...]; rebuild with the new length and
        // pad the remainder with 0xFF.
        let body = existing.isEmpty ? Data([0x00]) : existing.dropFirst()
        var field = Data([UInt8(targetLength - 1)])
        field.append(body)
        while field.count < targetLength {
            field.append(0xFF)
        }
        return field
    }

    /// PES header for a video access unit, carrying PTS only (no DTS: the
    /// source has no B-frames, so decode order equals presentation order).
    static func pesHeader(payloadSize: Int, pts: UInt64) -> Data {
        var header = Data([0x00, 0x00, 0x01, videoStreamID])

        // PES_packet_length covers everything after this field. Video
        // packets may exceed 65535 bytes, and the standard allows 0 to mean
        // "unbounded" for video — which is what a long access unit needs.
        let declared = payloadSize + 8
        if declared <= 0xFFFF {
            header.append(UInt8((declared >> 8) & 0xFF))
            header.append(UInt8(declared & 0xFF))
        } else {
            header.append(0x00)
            header.append(0x00)
        }

        header.append(0x80)                 // marker bits, no scrambling
        header.append(0x80)                 // PTS_DTS_flags = PTS only
        header.append(0x05)                 // PES_header_data_length
        header.append(contentsOf: Self.timestamp(pts, prefix: 0x02))
        return header
    }

    /// A 33-bit timestamp in the interleaved, marker-bit layout PES uses.
    /// `prefix` is 0b0010 for a PTS-only header.
    static func timestamp(_ value: UInt64, prefix: UInt8) -> [UInt8] {
        let ts = value & 0x1_FFFF_FFFF
        return [
            UInt8((prefix << 4) | UInt8((ts >> 30) & 0x07) << 1 | 0x01),
            UInt8((ts >> 22) & 0xFF),
            UInt8(((ts >> 14) & 0xFF) | 0x01),
            UInt8((ts >> 7) & 0xFF),
            UInt8(((ts << 1) & 0xFF) | 0x01)
        ]
    }

    // MARK: - Program tables

    /// Program Association Table: one program, whose map lives on `pmtPID`.
    static func patPayload() -> Data {
        var section = Data()
        section.append(0x00)                            // table_id: PAT
        // section_syntax_indicator(1) | '0' | reserved(11) | length(12).
        // The indicator and reserved bits are mandatory: a receiver that
        // reads PSI properly rejects a section without them, which shows up
        // as a program carrying no streams.
        section.append(contentsOf: [0xB0, 0x0D])         // length 13
        section.append(contentsOf: [0x00, 0x01])         // transport_stream_id
        section.append(0xC1)                            // version 0, current
        section.append(0x00)                            // section_number
        section.append(0x00)                            // last_section_number
        section.append(contentsOf: [0x00, 0x01])         // program_number 1
        section.append(UInt8(0xE0 | UInt8((pmtPID >> 8) & 0x1F)))
        section.append(UInt8(pmtPID & 0xFF))
        section.append(contentsOf: crc32MPEG(section).bigEndianBytes)
        // Sections are addressed from a pointer_field.
        return Data([0x00]) + section
    }

    /// Program Map Table: the program's single H.264 elementary stream.
    static func pmtPayload() -> Data {
        var section = Data()
        section.append(0x02)                            // table_id: PMT
        // length 18 = program_number(2) + version(1) + section_number(1) +
        // last_section_number(1) + PCR_PID(2) + program_info_length(2) +
        // stream_type(1) + elementary_PID(2) + ES_info_length(2) + CRC(4)
        section.append(contentsOf: [0xB0, 0x12])
        section.append(contentsOf: [0x00, 0x01])         // program_number
        section.append(0xC1)                            // version 0, current
        section.append(0x00)
        section.append(0x00)
        section.append(UInt8(0xE0 | UInt8((videoPID >> 8) & 0x1F)))
        section.append(UInt8(videoPID & 0xFF))           // PCR_PID = video PID
        section.append(contentsOf: [0xF0, 0x00])         // program_info_length 0
        section.append(h264StreamType)
        section.append(UInt8(0xE0 | UInt8((videoPID >> 8) & 0x1F)))
        section.append(UInt8(videoPID & 0xFF))
        section.append(contentsOf: [0xF0, 0x00])         // ES_info_length 0
        section.append(contentsOf: crc32MPEG(section).bigEndianBytes)
        return Data([0x00]) + section
    }

    /// CRC-32/MPEG-2: the polynomial and unreflected, non-inverted
    /// convention PSI sections use — not the same as zlib's CRC-32.
    static func crc32MPEG(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                if crc & 0x8000_0000 != 0 {
                    crc = (crc << 1) ^ 0x04C1_1DB7
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}
