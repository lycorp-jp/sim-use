// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import SimUse

@Suite("Android record-video argument construction")
struct AndroidRecordVideoArgumentTests {
    @Test("parseWMSize reads Physical size")
    func physicalSize() {
        let parsed = RecordVideo.parseWMSize("Physical size: 1080x2400\n")
        #expect(parsed?.width == 1080)
        #expect(parsed?.height == 2400)
    }

    @Test("parseWMSize prefers an Override size over Physical size")
    func overrideSizePreferred() {
        let output = "Physical size: 1080x2400\nOverride size: 720x1600\n"
        let parsed = RecordVideo.parseWMSize(output)
        #expect(parsed?.width == 720)
        #expect(parsed?.height == 1600)
    }

    @Test("parseWMSize returns nil for unparseable output")
    func unparseable() {
        #expect(RecordVideo.parseWMSize("cannot connect to display\n") == nil)
    }

    @Test("screenrecordArguments omits --time-limit below API 34")
    func api33NoTimeLimit() {
        let args = RecordVideo.screenrecordArguments(serial: "emu-1", sdk: 33, bitrate: nil, size: nil)
        #expect(args == ["-s", "emu-1", "exec-out", "screenrecord", "--output-format=h264", "-"])
    }

    @Test("screenrecordArguments adds --time-limit 0 on API 34+")
    func api34Unlimited() {
        let args = RecordVideo.screenrecordArguments(serial: "emu-1", sdk: 34, bitrate: nil, size: nil)
        #expect(args.contains("--time-limit"))
        #expect(args.contains("0"))
        #expect(args.last == "-")
    }

    @Test("screenrecordArguments includes --bit-rate and --size when provided")
    func bitrateAndSize() {
        let args = RecordVideo.screenrecordArguments(serial: "emu-1", sdk: 34, bitrate: 4_000_000, size: (width: 540, height: 1200))
        #expect(args == [
            "-s", "emu-1", "exec-out", "screenrecord", "--output-format=h264",
            "--time-limit", "0",
            "--bit-rate", "4000000",
            "--size", "540x1200",
            "-",
        ])
    }
}
