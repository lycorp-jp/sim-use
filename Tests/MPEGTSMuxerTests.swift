// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
@testable import SimUseVideo

/// Structural coverage for the transport-stream muxer. Every field asserted
/// here is fixed by ISO/IEC 13818-1, so these are conformance checks rather
/// than change detectors — a real player rejects a stream that breaks any of
/// them, and the E2E suite cannot say *which* field was wrong.
@Suite("MPEGTSMuxer")
struct MPEGTSMuxerTests {
    private func syntheticAccessUnit(isIDR: Bool, payloadBytes: Int = 200) -> H264AccessUnit {
        let type: UInt8 = isIDR ? 5 : 1
        var data = Data([type])
        data.append(Data(repeating: 0xAB, count: payloadBytes))
        return H264AccessUnit(nalUnits: [H264NALUnit(type: type, data: data)], isIDR: isIDR)
    }

    @Test("every packet is 188 bytes and starts with the sync byte")
    func packetFraming() {
        var muxer = MPEGTSMuxer()
        var stream = muxer.programTables()
        stream.append(muxer.packets(annexB: Data([0x00, 0x00, 0x00, 0x01, 0x65, 0xAA]), pts: 0, isIDR: true))

        #expect(stream.count % 188 == 0, "stream is not a whole number of packets: \(stream.count)")
        for offset in stride(from: 0, to: stream.count, by: 188) {
            #expect(stream[stream.startIndex + offset] == 0x47, "packet at \(offset) lacks the sync byte")
        }
    }

    @Test("program tables carry PAT then PMT on their reserved PIDs")
    func programTables() {
        var muxer = MPEGTSMuxer()
        let tables = muxer.programTables()
        #expect(tables.count == 188 * 2)

        func pid(ofPacketAt offset: Int) -> UInt16 {
            let hi = UInt16(tables[tables.startIndex + offset + 1] & 0x1F) << 8
            return hi | UInt16(tables[tables.startIndex + offset + 2])
        }
        #expect(pid(ofPacketAt: 0) == 0x0000, "first table must be the PAT on PID 0")
        #expect(pid(ofPacketAt: 188) == 0x1000, "second table must be the PMT")

        // Both are section starts.
        #expect(tables[tables.startIndex + 1] & 0x40 != 0)
        #expect(tables[tables.startIndex + 189] & 0x40 != 0)
    }

    @Test("continuity counters advance once per packet and wrap at 16")
    func continuityCounters() {
        var muxer = MPEGTSMuxer()
        // A payload long enough to need many packets on the video PID.
        let big = Data(repeating: 0x5A, count: 188 * 20)
        let stream = muxer.packets(annexB: big, pts: 0, isIDR: false)

        var expected: UInt8 = 0
        for offset in stride(from: 0, to: stream.count, by: 188) {
            let counter = stream[stream.startIndex + offset + 3] & 0x0F
            #expect(counter == expected, "continuity broke at packet \(offset / 188)")
            expected = (expected &+ 1) & 0x0F
        }
    }

    @Test("PTS round-trips through the marker-bit layout")
    func ptsEncoding() {
        // 90 kHz ticks for 1.5 s.
        let ticks: UInt64 = 135_000
        let bytes = MPEGTSMuxer.timestamp(ticks, prefix: 0x02)
        #expect(bytes.count == 5)
        // Marker bits are mandatory: low bit of bytes 0, 2 and 4.
        #expect(bytes[0] & 0x01 == 1)
        #expect(bytes[2] & 0x01 == 1)
        #expect(bytes[4] & 0x01 == 1)
        #expect(bytes[0] >> 4 == 0x02, "prefix nibble must mark a PTS-only header")

        let decoded = (UInt64(bytes[0] >> 1 & 0x07) << 30)
            | (UInt64(bytes[1]) << 22)
            | (UInt64(bytes[2] >> 1) << 15)
            | (UInt64(bytes[3]) << 7)
            | UInt64(bytes[4] >> 1)
        #expect(decoded == ticks, "PTS did not survive the round trip: \(decoded) != \(ticks)")
    }

    /// Parsed view of a PSI section, so the tests below can assert the header
    /// fields a real receiver reads rather than just the PID it arrived on.
    private struct PSISection {
        let tableID: UInt8
        let syntaxIndicator: Bool
        let reservedBits: UInt8      // the two bits after section_syntax_indicator + '0'
        let sectionLength: Int
        let body: Data               // table_id through CRC inclusive
    }

    private func parseSection(inPacketAt offset: Int, of stream: Data) throws -> PSISection {
        let base = stream.startIndex + offset
        try #require(stream[base] == 0x47)
        let adaptationControl = (stream[base + 3] >> 4) & 0x03
        var cursor = base + 4
        if adaptationControl == 2 || adaptationControl == 3 {
            cursor += Int(stream[cursor]) + 1        // adaptation_field_length + itself
        }
        cursor += Int(stream[cursor]) + 1            // pointer_field + itself
        let tableID = stream[cursor]
        let hi = stream[cursor + 1]
        let lo = stream[cursor + 2]
        let length = (Int(hi & 0x0F) << 8) | Int(lo)
        return PSISection(
            tableID: tableID,
            syntaxIndicator: hi & 0x80 != 0,
            reservedBits: (hi >> 4) & 0x03,
            sectionLength: length,
            body: Data(stream[cursor..<(cursor + 3 + length)])
        )
    }

    @Test("PAT is a syntactically valid section a receiver can parse")
    func patSectionHeader() throws {
        var muxer = MPEGTSMuxer()
        let tables = muxer.programTables()
        let pat = try parseSection(inPacketAt: 0, of: tables)

        #expect(pat.tableID == 0x00, "PAT table_id")
        #expect(pat.syntaxIndicator, "section_syntax_indicator must be 1 or a receiver cannot read the section")
        #expect(pat.reservedBits == 0x03, "the two reserved bits are set in a conformant section")
        // transport_stream_id(2) + version(1) + section_number(1) +
        // last_section_number(1) + program(2) + PMT PID(2) + CRC(4)
        #expect(pat.sectionLength == 13, "PAT section_length")
        // CRC-32/MPEG-2 over the whole section, CRC included, leaves zero.
        #expect(MPEGTSMuxer.crc32MPEG(pat.body) == 0, "PAT CRC does not verify")
    }

    @Test("PMT declares the H.264 stream and PCR PID a receiver needs")
    func pmtSectionHeader() throws {
        var muxer = MPEGTSMuxer()
        let tables = muxer.programTables()
        let pmt = try parseSection(inPacketAt: 188, of: tables)

        #expect(pmt.tableID == 0x02, "PMT table_id")
        #expect(pmt.syntaxIndicator, "section_syntax_indicator must be 1")
        #expect(pmt.reservedBits == 0x03)
        // program_number(2) + version(1) + section_number(1) +
        // last_section_number(1) + PCR_PID(2) + program_info_length(2) +
        // stream_type(1) + elementary_PID(2) + ES_info_length(2) + CRC(4)
        #expect(pmt.sectionLength == 18, "PMT section_length")
        #expect(MPEGTSMuxer.crc32MPEG(pmt.body) == 0, "PMT CRC does not verify")

        // The fields that actually associate the elementary stream: without
        // these a receiver sees a program with no streams.
        let b = pmt.body
        let pcrPID = (UInt16(b[b.startIndex + 8] & 0x1F) << 8) | UInt16(b[b.startIndex + 9])
        #expect(pcrPID == 0x0100, "PCR_PID must name the video PID, got \(String(pcrPID, radix: 16))")
        #expect(b[b.startIndex + 12] == 0x1B, "stream_type must be H.264 (0x1B)")
        let esPID = (UInt16(b[b.startIndex + 13] & 0x1F) << 8) | UInt16(b[b.startIndex + 14])
        #expect(esPID == 0x0100, "elementary_PID must be the video PID")
    }

    @Test("PSI sections use CRC-32/MPEG-2, not zlib's CRC")
    func psiChecksum() {
        // Known-answer test: CRC-32/MPEG-2 of "123456789".
        let crc = MPEGTSMuxer.crc32MPEG(Data("123456789".utf8))
        #expect(crc == 0x0376E6E7, "got \(String(crc, radix: 16))")
    }

    @Test("a keyframe's first packet carries the random-access flag and a PCR")
    func keyframeAdaptationField() {
        var muxer = MPEGTSMuxer()
        let stream = muxer.packets(annexB: Data(repeating: 0x11, count: 400), pts: 2.0, isIDR: true)
        // adaptation_field_control == 0b11 means field + payload.
        #expect((stream[stream.startIndex + 3] >> 4) & 0x03 == 0x03)
        let fieldLength = stream[stream.startIndex + 4]
        #expect(fieldLength > 0)
        let flags = stream[stream.startIndex + 5]
        #expect(flags & 0x40 != 0, "random_access_indicator must be set on an IDR")
        #expect(flags & 0x10 != 0, "PCR_flag must be set on an IDR")
    }

    @Test("a picture's PTS is ahead of the clock that delivers it")
    func ptsLeadsPCR() throws {
        var muxer = MPEGTSMuxer()
        let stream = muxer.packets(annexB: Data(repeating: 0x55, count: 400), pts: 2.0, isIDR: true)
        let base = stream.startIndex

        // The first packet carries both the adaptation field (with the PCR)
        // and the start of the PES (with the PTS).
        let adaptationLength = Int(stream[base + 4])
        #expect(stream[base + 5] & 0x10 != 0, "PCR_flag must be set")
        let pcr = (UInt64(stream[base + 6]) << 25) | (UInt64(stream[base + 7]) << 17)
            | (UInt64(stream[base + 8]) << 9) | (UInt64(stream[base + 9]) << 1)
            | (UInt64(stream[base + 10]) >> 7)

        let pesStart = base + 4 + adaptationLength + 1
        let p = stream[pesStart...]
        let pi = p.startIndex
        let pts = (UInt64((p[pi + 9] >> 1) & 0x07) << 30) | (UInt64(p[pi + 10]) << 22)
            | (UInt64(p[pi + 11] >> 1) << 15) | (UInt64(p[pi + 12]) << 7) | (UInt64(p[pi + 13] >> 1))

        // A receiver starts its clock from the PCR and presents the picture
        // when the clock reaches the PTS. With PTS == PCR the picture is due
        // the instant it arrives, leaving no time to decode it — ffmpeg
        // reports every such picture as `Packet corrupt`. The PTS has to
        // lead the clock that delivered it.
        #expect(pts > pcr, "PTS (\(pts)) must lead PCR (\(pcr)) so the picture can be decoded before it is due")
    }

    @Test("a compacted gap is signalled as a transport discontinuity")
    func discontinuityIsSignalled() {
        var muxer = MPEGTSMuxer()
        _ = muxer.packets(annexB: Data(repeating: 0x11, count: 200), pts: 1.0, isIDR: true)

        // A picture whose timeline gap was compacted arrives against a clock
        // that jumped. ISO/IEC 13818-1 2.4.3.4 has a bit for exactly this:
        // without it the jump is simply a broken clock, and a receiver that
        // disciplines its STC from the PCR has no way to know it should
        // resynchronise rather than treat the picture as wildly late.
        let after = muxer.packets(annexB: Data(repeating: 0x22, count: 200), pts: 1.2,
                                  isIDR: false, discontinuity: true)
        let flags = after[after.startIndex + 5]
        #expect(flags & 0x80 != 0, "discontinuity_indicator must be set on a compacted gap")

        // And it must not be set when the timeline ran normally, or a
        // receiver would resynchronise on every picture.
        let normal = muxer.packets(annexB: Data(repeating: 0x33, count: 200), pts: 1.24,
                                   isIDR: false, discontinuity: false)
        #expect(normal[normal.startIndex + 5] & 0x80 == 0, "discontinuity_indicator must stay clear normally")
    }

    @Test("a PCR-only packet carries no payload and does not consume a continuity number")
    func clockReferencePacketShape() {
        var muxer = MPEGTSMuxer()
        // Establish a continuity position on the video PID first.
        let frame = muxer.packets(annexB: Data(repeating: 0x33, count: 300), pts: 1.0, isIDR: true)
        let lastFrameCC = frame[frame.startIndex + (frame.count / 188 - 1) * 188 + 3] & 0x0F

        let pcr = muxer.clockReference(at: 1.5)
        #expect(pcr.count == 188)
        #expect(pcr[pcr.startIndex] == 0x47)

        // adaptation_field_control == 0b10: adaptation field only, no payload.
        // Signalling 0b11 while stuffing away all 184 bytes claims a payload
        // that is not there.
        let afc = (pcr[pcr.startIndex + 3] >> 4) & 0x03
        #expect(afc == 0x02, "PCR-only packet must signal adaptation-field-only, got 0b\(String(afc, radix: 2))")

        // ISO/IEC 13818-1 2.4.3.3: the counter does not advance on a packet
        // whose adaptation_field_control is '00' or '10'. So a PCR packet
        // repeats the current value without consuming it, and the next
        // payload packet takes that same number — leaving the payload-only
        // sequence unbroken, which is what a receiver checks for loss.
        let pcrCC = pcr[pcr.startIndex + 3] & 0x0F
        #expect(pcrCC == (lastFrameCC + 1) & 0x0F, "PCR packet carries the current counter value")

        let next = muxer.packets(annexB: Data(repeating: 0x44, count: 100), pts: 2.0, isIDR: false)
        let nextCC = next[next.startIndex + 3] & 0x0F
        #expect(nextCC == pcrCC, "the next payload packet consumes the number the PCR packet did not")

        // And it really does carry the clock.
        let flags = pcr[pcr.startIndex + 5]
        #expect(flags & 0x10 != 0, "PCR_flag must be set")
    }

    @Test("stuffing pads a short tail to exactly one packet")
    func shortTailIsStuffed() {
        var muxer = MPEGTSMuxer()
        // 10 bytes of payload cannot fill 184; the packet must still be 188.
        let stream = muxer.packets(annexB: Data(repeating: 0x22, count: 10), pts: 0, isIDR: false)
        #expect(stream.count == 188)
        #expect(stream[stream.startIndex] == 0x47)
    }

    @Test("IDR access units re-carry SPS and PPS")
    func idrCarriesParameterSets() {
        let sps = Data([0x67, 0x42, 0x00, 0x1F])
        let pps = Data([0x68, 0xCE, 0x3C, 0x80])

        let idr = MPEGTSStreamWriter.annexB(accessUnit: syntheticAccessUnit(isIDR: true), sps: sps, pps: pps)
        #expect(idr.range(of: sps) != nil, "IDR must carry SPS — an elementary stream has no avcC box")
        #expect(idr.range(of: pps) != nil, "IDR must carry PPS")

        let nonIDR = MPEGTSStreamWriter.annexB(accessUnit: syntheticAccessUnit(isIDR: false), sps: sps, pps: pps)
        #expect(nonIDR.range(of: sps) == nil, "non-IDR frames should not repeat parameter sets")
    }
}
