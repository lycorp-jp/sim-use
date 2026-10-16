// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import Foundation
import Testing

// Live coverage for video capture of the display that hosts the app
// (docs/ai/010-display-routing, S5). On an iPhone Duo the inner display is
// recorded and streamed from its own framebuffer; a fold during a
// recording keeps the display it started on and says so at the end. Runs
// only on a multi-display simulator (`ios fold` refuses the others).

/// Helpers shared with ResizeModeTests.
enum RoutedVideo {
    /// Runs `record-video` for `seconds`, stops it with SIGINT and returns
    /// its stderr.
    @discardableResult
    static func record(simUse: String, udid: String, output: URL, seconds: Double, during: (() async throws -> Void)? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: simUse)
        process.arguments = ["record-video", "--udid", udid, "--output", output.path]
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        try process.run()
        try await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1_000_000_000))
        try await during?()
        try await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1_000_000_000))
        process.interrupt()
        try await TestHelpers.waitForProcessExit(process, timeout: 15, description: "record-video did not stop")
        return String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// The first `seconds` of `stream-video --format h264`.
    static func stream(simUse: String, udid: String, seconds: Double) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: simUse)
        process.arguments = ["stream-video", "--udid", udid, "--format", "h264", "--fps", "10"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        let collected = DataBox()
        stdout.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
        try process.run()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        process.interrupt()
        try await TestHelpers.waitForProcessExit(process, timeout: 15, description: "stream-video did not stop")
        stdout.fileHandleForReading.readabilityHandler = nil
        return collected.data
    }

    static func videoSize(_ url: URL) async throws -> CGSize? {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        return try await tracks.first?.load(.naturalSize)
    }

    final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ chunk: Data) { lock.lock(); storage.append(chunk); lock.unlock() }
    }
}

@Suite("Video of the routing display", .serialized, .enabled(if: isE2EEnabled))
struct RoutedVideoTests {
    private static func fold(_ position: String, udid: String) async -> Bool {
        let result = try? await TestHelpers.runSimUseCommandAllowFailure("ios fold \(position)", simulatorUDID: udid)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return result?.exitCode == 0
    }

    @Test("the inner display is recorded and streamed from its own framebuffer")
    func innerDisplay() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        guard await Self.fold("open", udid: udid) else { return }
        do {
            try await TestHelpers.launchPlaygroundApp(to: "tap-test")

            let output = FileManager.default.temporaryDirectory.appendingPathComponent("inner-record-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            let stderr = try await RoutedVideo.record(simUse: simUse, udid: udid, output: output, seconds: 2.5)
            #expect(stderr.contains("(display 'LCD-1')"), "stderr: \(stderr)")
            // The 2007x2853 panel in its native portrait orientation, padded
            // to even dimensions for H.264.
            #expect(try await RoutedVideo.videoSize(output) == CGSize(width: 2008, height: 2854))

            let bytes = try await RoutedVideo.stream(simUse: simUse, udid: udid, seconds: 2.5)
            #expect(bytes.count > 10_000 && bytes.first == 0x47, "expected an MPEG-TS stream, got \(bytes.count) bytes")
        } catch {
            _ = await Self.fold("closed", udid: udid)
            throw error
        }
        // Restore the folded posture before the next test (awaited, not a
        // detached task that could run after the next test unfolds).
        _ = await Self.fold("closed", udid: udid)
    }

    @Test("a fold during a recording keeps the display it started on and says so")
    func foldDuringRecording() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        guard await Self.fold("open", udid: udid) else { return }
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("fold-record-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let stderr = try await RoutedVideo.record(simUse: simUse, udid: udid, output: output, seconds: 6) {
            _ = await Self.fold("closed", udid: udid)
        }
        #expect(stderr.contains("The app moved to the main display while `record-video` ran"), "stderr: \(stderr)")
        #expect(try await RoutedVideo.videoSize(output) == CGSize(width: 2008, height: 2854))
    }
}
