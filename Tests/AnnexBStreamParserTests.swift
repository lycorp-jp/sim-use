// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
@testable import iOSSimBackend

@Suite("AnnexBStreamParser NAL splitting and access-unit assembly")
struct AnnexBStreamParserTests {
    // Representative NAL units (header byte + short body). Bodies avoid any
    // `00 00 01`/`00 00 03` run so no accidental start code or emulation
    // sequence appears unless a test adds one deliberately.
    private static let sps: [UInt8] = [0x67, 0x42, 0x80, 0x1E, 0xAB]
    private static let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]
    private static let sei: [UInt8] = [0x06, 0x05, 0x01, 0xFF, 0x80]
    private static let idrMB0: [UInt8] = [0x65, 0x88, 0x84, 0x21]   // 0x88 → first_mb 0
    private static let sliceMB0: [UInt8] = [0x41, 0x9A, 0x12, 0x34] // 0x9A → first_mb 0
    private static let sliceMB1: [UInt8] = [0x41, 0x40, 0x0A, 0x0B] // 0x40 → first_mb 1
    private static let aud: [UInt8] = [0x09, 0x30]

    private func annexB(_ nalus: [[UInt8]], fourByte: Bool = false) -> Data {
        let startCode: [UInt8] = fourByte ? [0, 0, 0, 1] : [0, 0, 1]
        var out: [UInt8] = []
        for nalu in nalus {
            out.append(contentsOf: startCode)
            out.append(contentsOf: nalu)
        }
        return Data(out)
    }

    private func consumeAll(_ parser: AnnexBStreamParser, _ data: Data, chunkSize: Int) -> [H264AccessUnit] {
        var result: [H264AccessUnit] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            result.append(contentsOf: parser.consume(data.subdata(in: offset..<end)))
            offset = end
        }
        result.append(contentsOf: parser.flush())
        return result
    }

    @Test("Whole-buffer and byte-by-byte feeding yield identical access units")
    func chunkingIsInvariant() {
        let stream = annexB([
            Self.sps, Self.pps, Self.sei, Self.idrMB0, Self.sliceMB1,
            Self.sps, Self.pps, Self.sei, Self.idrMB0,
        ])

        let whole = consumeAll(AnnexBStreamParser(), stream, chunkSize: stream.count)
        let byteWise = consumeAll(AnnexBStreamParser(), stream, chunkSize: 1)
        let oddChunks = consumeAll(AnnexBStreamParser(), stream, chunkSize: 7)

        #expect(whole.count == 2)
        #expect(whole == byteWise)
        #expect(whole == oddChunks)
        #expect(whole[0].nalUnits.map(\.type) == [6, 5, 1]) // SEI, IDR, slice — params stripped
        #expect(whole[0].isIDR)
        #expect(whole[1].nalUnits.map(\.type) == [6, 5])
    }

    @Test("Four-byte start codes parse identically to three-byte")
    func fourByteStartCodes() {
        let nalus = [Self.sps, Self.pps, Self.idrMB0, Self.sliceMB1]
        let three = consumeAll(AnnexBStreamParser(), annexB(nalus), chunkSize: 5)
        let four = consumeAll(AnnexBStreamParser(), annexB(nalus, fourByte: true), chunkSize: 5)
        #expect(three == four)
        #expect(three.count == 1)
        #expect(three[0].nalUnits.map(\.type) == [5, 1])
    }

    @Test("Leading garbage before the first start code is ignored")
    func leadingGarbage() {
        var data = Data([0xAA, 0xBB, 0xCC])
        data.append(annexB([Self.idrMB0]))
        let aus = consumeAll(AnnexBStreamParser(), data, chunkSize: 2)
        #expect(aus.count == 1)
        #expect(aus[0].nalUnits.map(\.type) == [5])
    }

    @Test("SPS/PPS are captured and stripped from access units")
    func parameterSetsCapturedAndStripped() {
        let parser = AnnexBStreamParser()
        let aus = consumeAll(parser, annexB([Self.sps, Self.pps, Self.idrMB0]), chunkSize: 4)
        #expect(parser.currentSPS == Data(Self.sps))
        #expect(parser.currentPPS == Data(Self.pps))
        #expect(aus.count == 1)
        #expect(!aus[0].nalUnits.contains { $0.type == 7 || $0.type == 8 })
    }

    @Test("A NAL body containing 00 00 03 is not falsely split")
    func emulationSequenceInBodyNotSplit() {
        let spsWithEmulation: [UInt8] = [0x67, 0x00, 0x00, 0x03, 0x42, 0x80]
        let parser = AnnexBStreamParser()
        _ = consumeAll(parser, annexB([spsWithEmulation, Self.idrMB0]), chunkSize: 3)
        #expect(parser.currentSPS == Data(spsWithEmulation))
    }

    @Test("Consecutive mb==0 slices split into separate access units")
    func consecutiveKeyframesSplit() {
        let aus = consumeAll(AnnexBStreamParser(), annexB([Self.sliceMB0, Self.sliceMB0]), chunkSize: 3)
        #expect(aus.count == 2)
        #expect(aus.allSatisfy { $0.nalUnits.map(\.type) == [1] })
        #expect(aus.allSatisfy { !$0.isIDR })
    }

    @Test("A multi-slice picture stays a single access unit")
    func multiSliceSingleAU() {
        let aus = consumeAll(AnnexBStreamParser(), annexB([Self.idrMB0, Self.sliceMB1]), chunkSize: 5)
        #expect(aus.count == 1)
        #expect(aus[0].nalUnits.map(\.type) == [5, 1])
        #expect(aus[0].isIDR)
    }

    @Test("AUD delimiters bound access units and are dropped")
    func audBoundaries() {
        let aus = consumeAll(AnnexBStreamParser(), annexB([Self.aud, Self.idrMB0, Self.aud, Self.sliceMB0]), chunkSize: 3)
        #expect(aus.count == 2)
        #expect(aus.allSatisfy { !$0.nalUnits.contains { nalu in nalu.type == 9 } })
    }

    @Test("flush() on an empty parser returns no access units")
    func flushEmpty() {
        #expect(AnnexBStreamParser().flush().isEmpty)
    }

    // MARK: - Slice-header / bit-reading helpers

    @Test("first_mb_in_slice exp-Golomb decodes 0, 1, 5")
    func firstMBInSliceValues() {
        #expect(AnnexBStreamParser.firstMBInSlice(Data([0x41, 0x80])) == 0)
        #expect(AnnexBStreamParser.firstMBInSlice(Data([0x41, 0x40])) == 1)
        #expect(AnnexBStreamParser.firstMBInSlice(Data([0x41, 0x30])) == 5)
    }

    @Test("first_mb_in_slice returns nil for a header-only NAL unit")
    func firstMBInSliceTooShort() {
        #expect(AnnexBStreamParser.firstMBInSlice(Data([0x41])) == nil)
    }

    @Test("deEscape removes emulation-prevention bytes")
    func deEscapeRemovesEmulationBytes() {
        #expect(AnnexBStreamParser.deEscape([0x00, 0x00, 0x03, 0x41], maxBytes: 8) == [0x00, 0x00, 0x41])
        #expect(
            AnnexBStreamParser.deEscape([0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x01], maxBytes: 8)
                == [0x00, 0x00, 0x00, 0x00, 0x01]
        )
        // A lone 0x03 without two preceding zeros is data, not an escape.
        #expect(AnnexBStreamParser.deEscape([0x00, 0x03, 0x41], maxBytes: 8) == [0x00, 0x03, 0x41])
    }

    @Test("firstMBInSlice tolerates an emulation-prevention byte in the header")
    func firstMBInSliceWithEmulation() {
        // first_mb_in_slice = 5 (00110b) needs 5 header bits; pack them so a
        // 00 00 03 escape sits within the first RBSP bytes and must be removed
        // before the value reads back as 5.
        // RBSP after de-escape must begin 0x30 (0011 0000). Insert an escape
        // that de-escapes away without touching those leading bits.
        let nalu = Data([0x41, 0x30, 0x00, 0x00, 0x03, 0x00])
        #expect(AnnexBStreamParser.firstMBInSlice(nalu) == 5)
    }
}
