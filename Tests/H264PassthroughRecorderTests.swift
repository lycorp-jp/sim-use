// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import AVFoundation
import CoreMedia
@testable import iOSSimBackend

@Suite("H264PassthroughRecorder muxing")
struct H264PassthroughRecorderTests {
    // MARK: - Pure helpers

    @Test("avccData prefixes each NAL unit with a 4-byte big-endian length")
    func avccFraming() {
        let au = H264AccessUnit(
            nalUnits: [
                H264NALUnit(type: 5, data: Data([0x65, 0xAA])),
                H264NALUnit(type: 1, data: Data([0x41, 0xBB, 0xCC])),
            ],
            isIDR: true
        )
        let avcc = [UInt8](H264PassthroughRecorder.avccData(for: au))
        #expect(avcc == [0, 0, 0, 2, 0x65, 0xAA, 0, 0, 0, 3, 0x41, 0xBB, 0xCC])
    }

    @Test("normalizedPTS pins the first frame to zero and stays monotonic")
    func ptsMonotonic() {
        let first = H264PassthroughRecorder.normalizedPTS(hostTime: 100.0, firstHostTime: 100.0, lastPTS: .invalid)
        #expect(first == .zero)

        let second = H264PassthroughRecorder.normalizedPTS(hostTime: 100.5, firstHostTime: 100.0, lastPTS: first)
        #expect(second.seconds == 0.5)

        // A non-increasing host clock is bumped one tick past the last PTS.
        let bumped = H264PassthroughRecorder.normalizedPTS(hostTime: 100.4, firstHostTime: 100.0, lastPTS: second)
        #expect(bumped > second)
        #expect(bumped == CMTimeAdd(second, CMTime(value: 1, timescale: 600)))
    }

    // MARK: - Real mux round-trip

    private func loadFixtureAccessUnits(
        _ resource: String = "sample-annexb"
    ) throws -> (units: [H264AccessUnit], sps: Data, pps: Data) {
        let url = try #require(Bundle.module.url(forResource: resource, withExtension: "h264", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let parser = AnnexBStreamParser()
        var units = parser.consume(data)
        units.append(contentsOf: parser.flush())
        let sps = try #require(parser.currentSPS)
        let pps = try #require(parser.currentPPS)
        return (units, sps, pps)
    }

    @Test("Muxing the fixture stream produces a playable MP4 with the right frame count")
    func muxRoundTrip() async throws {
        let fixture = try loadFixtureAccessUnits()
        #expect(fixture.units.count == 10)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("simuse-mux-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let recorder = try H264PassthroughRecorder(outputURL: outputURL)
        var hostTime = 1000.0
        for unit in fixture.units {
            try recorder.append(accessUnit: unit, sps: fixture.sps, pps: fixture.pps, hostTime: hostTime)
            hostTime += 0.1 // ~10 fps
        }
        try await recorder.finish(stopHostTime: hostTime)

        #expect(recorder.framesAppended == 10)

        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
        let track = try #require(tracks.first)
        let dimensions = try await track.load(.naturalSize)
        #expect(Int(dimensions.width) == 160)
        #expect(Int(dimensions.height) == 120)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0.8)
    }

    @Test("Constant-rate mode lays frames out at exactly 1/fps")
    func constantRatePTS() async throws {
        let fixture = try loadFixtureAccessUnits()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("simuse-cfr-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let recorder = try H264PassthroughRecorder(outputURL: outputURL, frameRate: 30)
        // Deliberately jittery host times — CFR mode must ignore them.
        var hostTime = 0.0
        for (index, unit) in fixture.units.enumerated() {
            try recorder.append(accessUnit: unit, sps: fixture.sps, pps: fixture.pps, hostTime: hostTime)
            hostTime += (index % 2 == 0) ? 0.005 : 0.4
        }
        try await recorder.finish(stopHostTime: hostTime)

        let asset = AVURLAsset(url: outputURL)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let nominal = try await track.load(.nominalFrameRate)
        #expect(abs(nominal - 30) < 1.0, "expected ~30 fps constant rate, got \(nominal)")
        let duration = try await asset.load(.duration)
        // 10 frames at 30 fps → ~0.33 s regardless of the jittery host clock.
        #expect(abs(duration.seconds - 10.0 / 30.0) < 0.05, "expected ~0.33 s, got \(duration.seconds)")
    }

    @Test("finish with zero frames throws and leaves no file behind")
    func zeroFramesGracefulError() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("simuse-empty-\(UUID().uuidString).mp4")
        let recorder = try H264PassthroughRecorder(outputURL: outputURL)
        await #expect(throws: H264PassthroughError.noFramesCaptured) {
            try await recorder.finish(stopHostTime: 1.0)
        }
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }

    @Test("Re-appending identical parameter sets for a new segment does not error")
    func segmentRestartReusesFormat() throws {
        let fixture = try loadFixtureAccessUnits()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("simuse-seg-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let recorder = try H264PassthroughRecorder(outputURL: outputURL)
        var hostTime = 0.0
        for unit in fixture.units.prefix(3) {
            try recorder.append(accessUnit: unit, sps: fixture.sps, pps: fixture.pps, hostTime: hostTime)
            hostTime += 0.1
        }
        // Simulate a new segment feeding the same SPS/PPS bytes again.
        for unit in fixture.units.prefix(3) {
            try recorder.append(accessUnit: unit, sps: fixture.sps, pps: fixture.pps, hostTime: hostTime)
            hostTime += 0.1
        }
        recorder.invalidate()
        #expect(recorder.framesAppended == 6)
    }

    @Test("A dimension change between segments is rejected")
    func dimensionChangeRejected() throws {
        let small = try loadFixtureAccessUnits("sample-annexb")            // 160x120
        let large = try loadFixtureAccessUnits("sample-annexb-320x240")    // 320x240
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("simuse-dim-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let recorder = try H264PassthroughRecorder(outputURL: outputURL)
        try recorder.append(accessUnit: small.units[0], sps: small.sps, pps: small.pps, hostTime: 0)

        #expect(throws: H264PassthroughError.dimensionsChanged(old: "160x120", new: "320x240")) {
            try recorder.append(accessUnit: large.units[0], sps: large.sps, pps: large.pps, hostTime: 0.1)
        }
        recorder.invalidate()
    }
}
