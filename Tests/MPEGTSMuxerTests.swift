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
