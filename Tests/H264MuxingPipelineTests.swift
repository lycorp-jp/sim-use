// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import AVFoundation
@testable import iOSSimBackend

@Suite("H264MuxingPipeline chunked ingest")
struct H264MuxingPipelineTests {
    private func fixtureData() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "sample-annexb", withExtension: "h264", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// Deterministic 10 fps clock so PTS assertions don't depend on wall time.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = 500.0
        func tick() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            let value = t
            t += 0.1
            return value
        }
    }

    @Test("Chunked ingest muxes every frame into a playable MP4")
    func chunkedIngestProducesMP4() async throws {
        let data = try fixtureData()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("simuse-pipe-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let recorder = try H264PassthroughRecorder(outputURL: outputURL)
        let clock = FakeClock()
        let pipeline = H264MuxingPipeline(
            recorder: recorder,
            clock: { clock.tick() },
            onFatalError: { Issue.record("unexpected fatal error: \($0)") }
        )

        var offset = 0
        let chunk = 512
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            pipeline.ingest(data.subdata(in: offset..<end))
            offset = end
        }
        pipeline.finishIngest()
        try await recorder.finish(stopHostTime: clock.tick())

        #expect(pipeline.framesWritten == 10)
        #expect(pipeline.firstFrameReceived)
        #expect(!pipeline.hadFatalError)

        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
    }

    @Test("ingest after finishIngest is a no-op")
    func ingestAfterCloseIsNoOp() throws {
        let data = try fixtureData()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("simuse-pipe-closed-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let recorder = try H264PassthroughRecorder(outputURL: outputURL)
        let clock = FakeClock()
        let pipeline = H264MuxingPipeline(
            recorder: recorder,
            clock: { clock.tick() },
            onFatalError: { Issue.record("unexpected fatal error: \($0)") }
        )

        pipeline.ingest(data)
        pipeline.finishIngest()
        let framesAfterClose = pipeline.framesWritten
        pipeline.ingest(data) // must not append more
        #expect(pipeline.framesWritten == framesAfterClose)
        recorder.invalidate()
    }
}
