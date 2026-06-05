// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import Darwin
import AVFoundation

@Suite("Record Video Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct RecordVideoTests {
    // Regression for issue #35: under short-grace SIGTERM (process supervisor
    // pattern) the mp4 must still finalise with a moov atom. The signal-to-
    // finish path goes through a DispatchSource → Task → actor → loop pickup
    // → recorder.finish() chain whose latency on master is ~70-180 ms; with a
    // tight grace before SIGKILL the trailer is never written.
    @Test("Record video survives short-grace SIGTERM with a valid mp4")
    func recordVideoShortGraceSIGTERM() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUsePath = try TestHelpers.getSimUsePath()

        let iterations = 5
        let graceMillis: UInt64 = 100
        let recordDurationNanos: UInt64 = 3_000_000_000
        var failures: [String] = []

        for i in 1...iterations {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("sim-use-sigterm-test-\(UUID().uuidString).mp4")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: simUsePath)
            process.arguments = [
                "record-video",
                "--udid", udid,
                "--output", outputURL.path
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            try process.run()
            try await Task.sleep(nanoseconds: recordDurationNanos)

            kill(process.processIdentifier, SIGTERM)
            try await Task.sleep(nanoseconds: graceMillis * 1_000_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }

            try await TestHelpers.waitForProcessExit(
                process,
                timeout: 10.0,
                description: "record-video did not exit after SIGTERM/SIGKILL on iter \(i)"
            )

            let validity = await Self.validateMP4(at: outputURL)
            switch validity {
            case .valid:
                break
            case .missing:
                failures.append("iter \(i): output file missing")
            case .invalid(let reason):
                failures.append("iter \(i): \(reason)")
            }

            try? FileManager.default.removeItem(at: outputURL)
        }

        #expect(
            failures.isEmpty,
            "Recording must produce a valid mp4 even when SIGKILLed \(graceMillis) ms after SIGTERM. Failures (\(failures.count)/\(iterations)): \(failures.joined(separator: "; "))"
        )
    }

    private enum MP4Validity {
        case valid
        case missing
        case invalid(String)
    }

    private static func validateMP4(at url: URL) async -> MP4Validity {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.load(.tracks)
            guard !tracks.isEmpty else {
                return .invalid("mp4 has no tracks (moov atom likely missing)")
            }
            return .valid
        } catch {
            return .invalid("mp4 not loadable: \(error.localizedDescription)")
        }
    }

    @Test("Record video writes an MP4 file with default options")
    func recordVideoDefault() async throws {
        let result = try await invokeRecordVideo(duration: 3.0)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0)
        #expect(result.fileSize > 10_000, "Recorded file should be non-empty and usable (got: \(result.fileSize))")
        #expect(result.stderr.contains("Recording simulator"))
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == result.outputURL.path)
    }

    @Test("Record video honours FPS, scale, and quality settings")
    func recordVideoCustomOptions() async throws {
        let result = try await invokeRecordVideo(fps: 5, quality: 60, scale: 0.5, duration: 2.0)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0)
        #expect(result.fileSize > 10_000)
        #expect(result.stderr.contains("Press Ctrl+C"))
    }

    @Test("Record video uses provided directory without deleting its contents")
    func recordVideoOutputDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-record-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let sentinel = tempDir.appendingPathComponent("sentinel.txt")
        try "sentinel".write(to: sentinel, atomically: true, encoding: .utf8)

        let result = try await invokeRecordVideo(duration: 1.0, outputPath: tempDir.path)

        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect(result.exitCode == 0)
        #expect(result.fileSize > 0)
        #expect(result.outputURL.path.hasPrefix(tempDir.path))
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Record video validates FPS input")
    func recordVideoInvalidFPS() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUsePath = try TestHelpers.getSimUsePath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: simUsePath)
        process.arguments = [
            "record-video",
            "--udid", udid,
            "--fps", "40"
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(process.terminationStatus != 0)
        #expect(errorOutput.contains("FPS must be between 1 and 30"))
    }

    // MARK: - Helpers

    private struct RecordingResult {
        let outputURL: URL
        let stdout: String
        let stderr: String
        let fileSize: Int
        let exitCode: Int32
    }

    private func invokeRecordVideo(
        fps: Int = 10,
        quality: Int = 80,
        scale: Double = 1.0,
        duration: TimeInterval = 2.0,
        outputPath: String? = nil
    ) async throws -> RecordingResult {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUsePath = try TestHelpers.getSimUsePath()

        let defaultOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-record-test-\(UUID().uuidString).mp4")
        let configuredOutputPath = outputPath ?? defaultOutputURL.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: simUsePath)
        process.arguments = [
            "record-video",
            "--udid", udid,
            "--fps", "\(fps)",
            "--quality", "\(quality)",
            "--scale", "\(scale)",
            "--output", configuredOutputPath
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        process.interrupt()
        try await TestHelpers.waitForProcessExit(
            process,
            timeout: 10.0,
            description: "record-video process did not exit after interrupt"
        )

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let resolvedOutputPath = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedURL = resolvedOutputPath.isEmpty ? defaultOutputURL : URL(fileURLWithPath: resolvedOutputPath)

        var fileSize = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path),
           let sizeNumber = attributes[.size] as? NSNumber {
            fileSize = sizeNumber.intValue
        }

        if outputPath == nil {
            try? FileManager.default.removeItem(at: resolvedURL)
        }

        return RecordingResult(
            outputURL: resolvedURL,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            fileSize: fileSize,
            exitCode: process.terminationStatus
        )
    }
}