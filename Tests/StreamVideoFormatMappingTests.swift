// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend

/// Pins the top-level `stream-video` format union: `h264` and the
/// screenshot-backed formats map onto both backends, while the one
/// platform-exclusive format (`bgra`, iOS-only) maps to nil on Android so
/// the forwarder fails with a redirect instead of forwarding an
/// impossible format.
@Suite("StreamVideo format mapping")
struct StreamVideoFormatMappingTests {
    @Test("every format maps onto the iOS backend enum")
    func iosFormats() {
        #expect(StreamVideo.iosFormat(for: .mjpeg) == .mjpeg)
        #expect(StreamVideo.iosFormat(for: .raw) == .raw)
        #expect(StreamVideo.iosFormat(for: .ffmpeg) == .ffmpeg)
        #expect(StreamVideo.iosFormat(for: .bgra) == .bgra)
        #expect(StreamVideo.iosFormat(for: .h264) == .h264)
    }

    @Test("shared formats map onto the Android backend enum")
    func androidSharedFormats() {
        #expect(StreamVideo.androidFormat(for: .mjpeg) == .mjpeg)
        #expect(StreamVideo.androidFormat(for: .raw) == .raw)
        #expect(StreamVideo.androidFormat(for: .ffmpeg) == .ffmpeg)
        #expect(StreamVideo.androidFormat(for: .h264) == .h264)
    }

    @Test("bgra has no Android mapping")
    func androidRejectsBGRA() {
        #expect(StreamVideo.androidFormat(for: .bgra) == nil)
    }

    @Test("default format is mjpeg, matching the per-platform subcommands")
    func defaultFormat() throws {
        let command = try StreamVideo.parse(["--udid", "00000000-0000-0000-0000-000000000000"])
        #expect(command.format == .mjpeg)
    }

    @Test("h264 parses at the top level and routes to either platform")
    func h264Parses() throws {
        let android = try StreamVideo.parse(["--format", "h264", "--udid", "emulator-5554"])
        #expect(android.format == .h264)
        let ios = try StreamVideo.parse(["--format", "h264", "--udid", "00000000-0000-0000-0000-000000000000"])
        #expect(ios.format == .h264)
    }

    // The deprecation is per-platform on purpose: on a simulator `h264`
    // strictly dominates the screenshot loop, but on Android the same loop
    // is the only way to stream from a device whose `screenrecord` does not
    // work. Pinning it here so the asymmetry is not "tidied up" later.
    @Test("the screenshot formats are deprecated on iOS only")
    func deprecationIsIOSOnly() {
        #expect(IOSSimStreamVideoCommand.OutputFormat.mjpeg.isDeprecated)
        #expect(IOSSimStreamVideoCommand.OutputFormat.raw.isDeprecated)
        #expect(IOSSimStreamVideoCommand.OutputFormat.ffmpeg.isDeprecated)
        #expect(!IOSSimStreamVideoCommand.OutputFormat.h264.isDeprecated)
        // Raw pixels are not something H.264 substitutes for.
        #expect(!IOSSimStreamVideoCommand.OutputFormat.bgra.isDeprecated)

        let notice = IOSSimStreamVideoCommand.OutputFormat.mjpeg.deprecationNotice
        #expect(notice.contains("h264"), "the notice must name the replacement")
        #expect(notice.contains("mjpeg"), "the notice must name the format being used")
    }

    // stdout carries the raw video bytes, so the summary envelope can never
    // share it — all three surfaces must reject the flag at validation time
    // rather than corrupt the stream after the fact.
    @Test("--json is rejected on every stream-video surface")
    func jsonRejectedEverywhere() {
        #expect(throws: (any Error).self) {
            _ = try StreamVideo.parse(["--json", "--udid", "00000000-0000-0000-0000-000000000000"])
        }
        #expect(throws: (any Error).self) {
            _ = try AndroidStreamVideoCommand.parse(["--json", "--device", "emulator-5554"])
        }
        #expect(throws: (any Error).self) {
            _ = try IOSSimStreamVideoCommand.parse(["--json", "--udid", "00000000-0000-0000-0000-000000000000"])
        }
    }
}
