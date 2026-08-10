// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Android Stream Video Tests", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidStreamVideoTests {
    @Test("h264 passthrough emits Annex B bytes and stops cleanly on SIGTERM")
    func h264Smoke() async throws {
        let result = try await streamForDuration(format: "h264", duration: 4.0)

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        #expect(result.stderr.contains("h264 Annex B passthrough"))
        #expect(result.stdout.count > 1_000, "expected a real byte stream, got \(result.stdout.count) bytes")
        // screenrecord's stream opens with an Annex B start code (SPS).
        #expect(result.stdout.starts(with: [0x00, 0x00, 0x00, 0x01]))
    }

    @Test("mjpeg stream carries iOS-parity multipart framing")
    func mjpegSmoke() async throws {
        let result = try await streamForDuration(format: "mjpeg", duration: 4.0)

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        let frame = try firstMJPEGFrame(in: result.stdout)
        #expect(frame.contentType == "image/jpeg")
        #expect(frame.contentLength == frame.payload.count)
        #expect(frame.payload.starts(with: [0xFF, 0xD8]))
        #expect(result.stderr.contains("Format: mjpeg"))
    }

    @Test("raw format prefixes each frame with a 4-byte length")
    func rawFraming() async throws {
        let result = try await streamForDuration(format: "raw", duration: 3.0)

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        try #require(result.stdout.count > 8)
        let length = result.stdout.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // The prefix must describe a plausible frame that the stream had
        // room to carry (screencap frames are tens of KB to a few MB).
        #expect(length > 100)
        #expect(Int(length) <= result.stdout.count)
    }

    @Test("h264 stream survives a screenrecord segment restart")
    func segmentRestart() async throws {
        // The override forces 2-second screenrecord segments, so a ~7 s
        // stream must cross at least one restart boundary.
        let result = try await streamForDuration(
            format: "h264",
            duration: 7.0,
            environment: ["SIM_USE_SCREENRECORD_TIME_LIMIT": "2"]
        )

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        #expect(result.stderr.contains("restarting stream"), "expected a segment restart, stderr: \(result.stderr)")
        #expect(result.stdout.count > 1_000)
    }

    @Test("consumer hangup ends the stream without error")
    func consumerHangup() async throws {
        let serial = try AndroidE2E.requireSerial()
        let simUsePath = try TestHelpers.getSimUsePath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: simUsePath)
        process.arguments = ["android", "stream-video", "--format", "h264", "--device", serial]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Let the stream produce some bytes, then hang up the consumer end.
        // The unread pipe may already be full by then — the child's blocked
        // write must fail over to EPIPE, not wedge.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        stdoutPipe.fileHandleForReading.closeFile()

        try await TestHelpers.waitForProcessExit(
            process,
            timeout: 10.0,
            description: "stream-video did not exit after the consumer closed stdout"
        )

        let stderrText = String(
            decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        // Hangup is an orderly stop: summary printed, exit 0 — not a crash.
        #expect(process.terminationStatus == 0, "expected clean exit, got \(process.terminationStatus); stderr: \(stderrText)")
        #expect(stderrText.contains("Streamed"))
    }

    // MARK: - Helpers

    private func streamForDuration(
        format: String,
        duration: TimeInterval,
        environment: [String: String] = [:]
    ) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        let serial = try AndroidE2E.requireSerial()
        let simUsePath = try TestHelpers.getSimUsePath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: simUsePath)
        process.arguments = ["android", "stream-video", "--format", format, "--device", serial]
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain stdout continuously so the child never blocks on a full pipe.
        let stdoutReadTask = Task {
            try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        }

        try process.run()
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        process.terminate()

        try await TestHelpers.waitForProcessExit(
            process,
            timeout: 10.0,
            description: "stream-video process did not exit after terminate"
        )

        let stdout = (try? await stdoutReadTask.value) ?? Data()
        let stderrText = String(
            decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return (stdout: stdout, stderr: stderrText, exitCode: process.terminationStatus)
    }

    private func isAcceptableStreamExitCode(_ code: Int32) -> Bool {
        // 0 = clean stop, the rest are signal-mediated exits a supervisor
        // may surface (SIGTERM/SIGKILL/SIGINT variants).
        let acceptable: Set<Int32> = [0, 9, 15, 130, 137, 143]
        return acceptable.contains(code)
    }
}
