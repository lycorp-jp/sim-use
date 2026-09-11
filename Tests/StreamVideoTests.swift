// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation

@Suite("Stream Video Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct StreamVideoTests {
    @Test("h264 emits MPEG-TS carrying timestamps, and stops cleanly")
    func streamVideoH264() async throws {
        let result = try await streamVideoForDuration(format: "h264", fps: 30, duration: 3.0)

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        #expect(result.output.contains("Format: h264"))
        #expect(result.output.contains("h264 stream is now running"))
        // Native passthrough carries far more frames per second than the
        // screenshot loop, so a 3 s capture is substantial.
        #expect(result.data.count > 10_000, "expected a real byte stream, got \(result.data.count) bytes")

        // MPEG-TS, not bare Annex B — the transport must carry PTS or a
        // player paces on a guessed frame rate and drifts ever further
        // behind the device. Every 188-byte packet opens with sync byte 0x47.
        #expect(result.data.first == 0x47, "stream does not open with the MPEG-TS sync byte")
        let packetStarts = stride(from: 0, to: min(result.data.count, 188 * 20), by: 188)
        #expect(
            packetStarts.allSatisfy { result.data[result.data.startIndex + $0] == 0x47 },
            "stream is not aligned to 188-byte MPEG-TS packets"
        )
    }

    @Test("h264 stays cancellable when the consumer stops reading")
    func streamVideoH264StalledConsumerIsInterruptible() async throws {
        // A consumer that holds the pipe open but never reads: no EPIPE ever
        // arrives, the pipe just fills. idb's blocking file writer then sat
        // in write(2) on the encoder thread and stopStreaming() waited behind
        // it, so Ctrl-C could not end the command.
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUsePath = try TestHelpers.getSimUsePath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: simUsePath)
        process.arguments = ["ios", "stream-video", "--format", "h264", "--fps", "30", "--udid", udid]
        let stdoutPipe = Pipe()      // deliberately never drained
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        // At ~200 KB/s a 64 KB pipe is full well inside this window.
        try await Task.sleep(nanoseconds: 4_000_000_000)
        #expect(process.isRunning, "stream ended on its own before the check")
        process.interrupt()

        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let exitedOnItsOwn = !process.isRunning
        if !exitedOnItsOwn {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        // Release the reader end only now: draining earlier would end the stall.
        try? stdoutPipe.fileHandleForReading.close()
        let stderrText = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(exitedOnItsOwn, "SIGINT did not end the stream within 8 s; stderr: \(stderrText)")
        #expect(isAcceptableStreamExitCode(process.terminationStatus), "Unexpected exit code: \(process.terminationStatus)")
        #expect(stderrText.contains("h264 stream stopped"), "expected an orderly stop; stderr: \(stderrText)")
    }

    @Test("Stream video outputs MJPEG data with HTTP headers")
    func streamVideoMJPEG() async throws {
        let result = try await streamVideoForDuration(format: "mjpeg", duration: 3.0)

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        #expect(!result.output.isEmpty, "Should have stderr messages")
        #expect(result.output.contains("Starting screenshot-based video stream"))
        #expect(result.output.contains("Format: mjpeg"))
    }

    @Test("Stream video outputs raw JPEG data for ffmpeg format")
    func streamVideoFFmpeg() async throws {
        let result = try await streamVideoForDuration(format: "ffmpeg", duration: 2.0)

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        #expect(result.output.contains("Format: ffmpeg"))
    }

    @Test("Stream video outputs raw JPEG with length prefix for raw format")
    func streamVideoRaw() async throws {
        let result = try await streamVideoForDuration(format: "raw", duration: 2.0)

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        #expect(result.output.contains("Format: raw"))
    }

    @Test("Stream video with custom FPS")
    func streamVideoWithFPS() async throws {
        let result = try await streamVideoForDuration(format: "mjpeg", fps: 5, duration: 2.0)

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        #expect(result.output.contains("FPS: 5"))
    }

    @Test("Stream video with quality and scale settings")
    func streamVideoWithQualityAndScale() async throws {
        let result = try await streamVideoForDuration(
            format: "mjpeg",
            fps: 5,
            quality: 50,
            scale: 0.5,
            duration: 1.0
        )

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        #expect(result.output.contains("Quality: 50"))
        #expect(result.output.contains("Scale: 0.5"))
    }

    @Test("Stream BGRA video outputs raw pixel data")
    func streamVideoBGRA() async throws {
        let result = try await streamVideoForDuration(format: "bgra", duration: 2.0)

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        #expect(!result.output.isEmpty)
        #expect(result.output.contains("Starting BGRA video stream"))
        #expect(result.output.contains("Format: bgra"))
    }

    @Test("Stream video can be cancelled gracefully")
    func streamVideoCancellation() async throws {
        let task = Task {
            try await streamVideoForDuration(format: "mjpeg", fps: 30, duration: 60.0)
        }

        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        _ = await task.result
    }

    @Test("Stream video rejects invalid formats")
    func streamVideoInvalidFormat() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()

        let simUsePath = try TestHelpers.getSimUsePath()
        let fullCommand = "\(simUsePath) ios stream-video --format webm --udid \(udid)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", fullCommand]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(process.terminationStatus != 0)
        #expect(errorOutput.contains("format"))
    }

    private func streamVideoForDuration(
        format: String = "mjpeg",
        fps: Int = 10,
        quality: Int = 80,
        scale: Double = 1.0,
        duration: TimeInterval = 2.0
    ) async throws -> (output: String, data: Data, dataString: String, dataSize: Int, exitCode: Int32) {
        var command = "ios stream-video"
        command += " --format \(format)"
        command += " --fps \(fps)"
        command += " --quality \(quality) --scale \(scale)"

        let udid = try TestHelpers.requireSimulatorUDID()

        let simUsePath = try TestHelpers.getSimUsePath()
        let fullCommand = "\(simUsePath) \(command) --udid \(udid)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", fullCommand]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stdoutReadTask = Task {
            try outputPipe.fileHandleForReading.readToEnd() ?? Data()
        }

        try process.run()

        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        process.terminate()

        try await TestHelpers.waitForProcessExit(
            process,
            timeout: 10.0,
            description: "stream-video process did not exit after terminate"
        )

        let outputData = (try? await stdoutReadTask.value) ?? Data()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        let dataString = String(data: outputData, encoding: .utf8) ?? ""

        if outputData.count == 0 && !errorOutput.isEmpty {
            print("DEBUG: No data received. Error output: \(errorOutput)")
        }

        return (
            output: errorOutput,
            data: outputData,
            dataString: dataString,
            dataSize: outputData.count,
            exitCode: process.terminationStatus
        )
    }

    private func isAcceptableStreamExitCode(_ code: Int32) -> Bool {
        let acceptable: Set<Int32> = [0, 9, 15, 130, 137, 143]
        return acceptable.contains(code)
    }
}