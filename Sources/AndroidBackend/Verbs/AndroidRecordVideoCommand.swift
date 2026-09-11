// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import AVFoundation
import CoreMedia
import SimUseCore
import SimUseVideo

/// `sim-use android record-video` — record the device display to an MP4.
///
/// Native capture pipes `adb exec-out screenrecord --output-format=h264 -`
/// into the shared H.264 → MP4 passthrough muxer (`H264MuxingPipeline`)
/// for variable-frame-rate recording, falling back to a legacy
/// `screencap`-per-frame loop (≈7–8 FPS) only if screenrecord cannot
/// start.
///
/// The bridge `/screenshot` path is NOT used: it goes through
/// `AccessibilityService.takeScreenshot`, which the Android framework
/// rate-limits to ~2 FPS — unusable for video.
public struct AndroidRecordVideoCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "record-video",
        abstract: "Record the Android device display to an MP4 (H.264) or animated GIF file"
    )

    public struct ExecutionResult: Codable {
        public let path: String
        public init(path: String) {
            self.path = path
        }
    }

    @OptionGroup public var device: AndroidDeviceOptions

    @Option(help: "Frames per second (1-60). Ignored by native screenrecord capture (records at the device's variable frame rate); paces the screencap fallback (default: 10) and samples a GIF (default: 10).")
    public var fps: Int?

    @Option(help: "Quality factor (1-100) controlling bitrate (default: 80)")
    public var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0; default: 1.0 for mp4, 0.5 for gif)")
    public var scale: Double?

    @Option(help: "Output format: mp4, gif. Defaults to the --output extension when recognized, else mp4.")
    public var format: RecordingFormat?

    @Flag(help: "Bracket a GIF with START/END marker frames (opt-in; ignored for mp4).")
    public var gifMarkers: Bool = false

    @Option(help: "Output file path. Defaults to sim-use-video-<timestamp>.<format> in the current directory.")
    public var output: String?

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {path}}` envelope on success. Mirrors the cross-platform `record-video --json` shape.")
    public var jsonOutput: Bool = false

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    /// Long-running, signal-driven, and resolves `--output` against the
    /// caller's cwd — none of which survive the daemon hop. Mirrors the
    /// top-level `RecordVideo` posture.
    public var daemonBypass: Bool { true }

    public func validate() throws {
        try VideoRecordingOptions.validate(fps: fps, quality: quality, scale: scale)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(
            stdout: result.path + "\n",
            stderr: "Recording saved to \(result.path)\n"
        )
    }

    public func execute() async throws -> ExecutionResult {
        let outputURL = try await Self.record(
            serial: device.resolved,
            output: output,
            format: format,
            fps: fps,
            quality: quality,
            scale: scale,
            gifMarkers: gifMarkers
        )
        return ExecutionResult(path: outputURL.path)
    }

    // MARK: - Shared orchestration

    /// Raised only when `adb screenrecord` cannot produce an H.264 stream
    /// (unsupported args, encoder unavailable). Triggers the legacy
    /// screencap-frame fallback; mid-recording failures propagate as-is.
    private struct ScreenrecordUnavailableError: Error {
        let underlying: String
    }

    /// Reusable Android recording entry point: runs until SIGINT/SIGTERM,
    /// then finalizes the MP4 (transcoding to GIF when requested) and
    /// returns the output URL. The top-level cross-platform `RecordVideo`
    /// forwards here for Android UDIDs so both
    /// `sim-use android record-video` and `sim-use record-video` go
    /// through one body — symmetric to
    /// `AndroidScreenshotCommand.performScreenshot`.
    public static func record(
        serial: String,
        output: String?,
        format: RecordingFormat?,
        fps: Int?,
        quality: Int,
        scale: Double?,
        gifMarkers: Bool
    ) async throws -> URL {
        let adb = Adb()
        try assertAdbDeviceOnline(adb: adb, serial: serial)

        // GIF is transcoded from a finished MP4 (see GIFTranscoder); the
        // capture loop itself always writes H.264, to plan.recordTarget.
        let plan = try RecordingOutputPlan(format: format, output: output, fps: fps, scale: scale, gifMarkers: gifMarkers)
        let options = plan.options
        let recordTarget = plan.recordTarget
        // Native screenrecord capture is variable-frame-rate either way;
        // the flag still paces the screencap fallback and GIF sampling,
        // so only claim it is ignored when neither applies.
        if fps != nil && options.format == .mp4 {
            FileHandle.standardError.write(Data("note: --fps is ignored by Android native capture (screenrecord records at its variable frame rate)\n".utf8))
        }
        FileHandle.standardError.write(Data("Recording Android device \(serial) to \(plan.outputURL.path)\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop recording\n".utf8))

        let cancellationFlag = CancellationFlag()
        let recordingFinished = CancellationFlag()
        let signalObserver = SignalObserver(signals: [SIGINT, SIGTERM]) {
            cancellationFlag.cancel()
            RecordingFinishWatchdog.arm(recordingFinished: recordingFinished)
        }
        defer { signalObserver.invalidate() }

        do {
            try await recordVideoAndroidStream(
                adb: adb,
                serial: serial,
                outputURL: recordTarget,
                quality: quality,
                scale: options.scale,
                cancellationFlag: cancellationFlag
            )
            recordingFinished.cancel()
        } catch let unavailable as ScreenrecordUnavailableError {
            FileHandle.standardError.write(Data("warning: screenrecord unavailable (\(unavailable.underlying)); falling back to screencap frames\n".utf8))
            do {
                try await recordVideoAndroidScreencapLegacy(
                    adb: adb,
                    serial: serial,
                    outputURL: recordTarget,
                    fps: options.fps ?? 10,
                    quality: quality,
                    scale: options.scale,
                    cancellationFlag: cancellationFlag
                )
                recordingFinished.cancel()
            } catch {
                recordingFinished.cancel()
                throw CLIError(errorDescription: "Failed to record video: \(error.localizedDescription)")
            }
        } catch {
            recordingFinished.cancel()
            throw CLIError(errorDescription: "Failed to record video: \(error.localizedDescription)")
        }

        // Tear the observer down before the transcode so Ctrl+C during a
        // long GIF encode kills the process instead of being swallowed by
        // a handler that has nothing left to cancel (invalidate is
        // idempotent; the defer covers the error paths above).
        signalObserver.invalidate()
        try await plan.finalizeRecording()
        return plan.outputURL
    }

    static func assertAdbDeviceOnline(adb: Adb, serial: String) throws {
        let devices: [Adb.Device]
        do {
            devices = try adb.devices()
        } catch {
            throw CLIError(errorDescription: "Failed to query adb devices: \(error.localizedDescription)")
        }
        guard let match = devices.first(where: { $0.serial == serial }) else {
            throw CLIError(errorDescription: "Android device \(serial) not found. Run `adb devices` to verify it is attached.")
        }
        guard match.isOnline else {
            throw CLIError(errorDescription: "Android device \(serial) is \(match.state), not 'device'. Check authorization / emulator state.")
        }
    }

    /// Native capture: `adb exec-out screenrecord --output-format=h264 -`
    /// streamed into the shared muxer. On API < 34 `screenrecord` self-limits
    /// to 180 s per invocation, so we restart it in a loop and keep feeding
    /// the same muxer — the single host clock keeps PTS continuous across the
    /// ~100–300 ms restart gap.
    private static func recordVideoAndroidStream(
        adb: Adb,
        serial: String,
        outputURL: URL,
        quality: Int,
        scale: Double,
        cancellationFlag: CancellationFlag
    ) async throws {
        let sdk = detectSDK(adb: adb, serial: serial)
        // Detect the display size unconditionally so --quality maps to a
        // bitrate even at the default scale — only the --size *argument* is
        // scale-gated below. If `wm size` is unparseable, bitrate is omitted
        // (screenrecord's own 20 Mbps default) rather than failing the recording.
        let baseSize = detectSize(adb: adb, serial: serial)
        let recordingSize = scale < 1.0 ? baseSize.map { scaledSize($0, scale: scale) } : nil
        let bitrateSize = recordingSize ?? baseSize
        let bitrate = bitrateSize.map { H264StreamRecorder.estimateBitrate(width: $0.width, height: $0.height, fps: 30, quality: quality) }
        let arguments = screenrecordArguments(serial: serial, sdk: sdk, bitrate: bitrate, size: recordingSize, timeLimitOverride: screenrecordTimeLimitOverride())

        let recorder = try H264PassthroughRecorder(outputURL: outputURL)
        var recorderFinalized = false
        defer { if !recorderFinalized { recorder.invalidate() } }

        let fatalBox = FirstErrorBox()
        let pipeline = H264MuxingPipeline(sink: recorder, onFatalError: { error in
            fatalBox.set(error)
            cancellationFlag.cancel()
        })

        var firstSegment = true
        // Set when the stream ends abnormally (device stopped feeding or
        // screenrecord died); the recorder still finalizes so the partial
        // MP4 survives, then the failure surfaces as the thrown error.
        var streamFailure: String?

        segmentLoop: while true {
            if Task.isCancelled || cancellationFlag.isCancelled() || fatalBox.first != nil { break }

            pipeline.resetParserForNewSegment()
            let process = AdbStreamingProcess(
                adbPath: adb.binaryPath,
                arguments: arguments,
                onStdout: { pipeline.ingest($0) }
            )
            do {
                try process.start()
            } catch {
                if firstSegment {
                    throw ScreenrecordUnavailableError(underlying: error.localizedDescription)
                }
                throw error
            }
            firstSegment = false

            let segmentStartBytes = process.stdoutByteCount
            while process.isRunning {
                if Task.isCancelled || cancellationFlag.isCancelled() || fatalBox.first != nil { break }
                try? await cancellableSleep(seconds: 0.05, flag: cancellationFlag)
            }

            let stopping = Task.isCancelled || cancellationFlag.isCancelled() || fatalBox.first != nil
            if stopping {
                process.interrupt()
                process.waitForExit(timeout: 2)
                break
            }

            // The process exited on its own — a clean exit 0 is the API-level
            // time limit (restart to continue); anything else is a dead
            // device, adb, or encoder, which must NOT be blind-restarted
            // into a crash loop just because the segment produced bytes.
            let exitCode = process.waitForExit(timeout: 2)
            let bytesThisSegment = process.stdoutByteCount - segmentStartBytes
            let stderrTail = process.collectedStderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if bytesThisSegment == 0 {
                if !pipeline.firstFrameReceived {
                    let exitDescription = exitCode.map(String.init) ?? "timeout"
                    throw ScreenrecordUnavailableError(
                        underlying: "screenrecord produced no output (exit \(exitDescription)): \(stderrTail)"
                    )
                }
                streamFailure = "Android device stopped producing frames during recording"
                break segmentLoop
            }
            guard exitCode == 0 else {
                let exitDescription = exitCode.map(String.init) ?? "timeout"
                streamFailure = "screenrecord exited unexpectedly (exit \(exitDescription)): \(stderrTail)"
                break segmentLoop
            }
            FileHandle.standardError.write(Data("screenrecord segment ended (Android time limit); restarting (~100-300ms gap)\n".utf8))
        }

        pipeline.finishIngest()
        do {
            try await recorder.finish(stopHostTime: ProcessInfo.processInfo.systemUptime)
            recorderFinalized = true
        } catch {
            if let fatal = fatalBox.first { throw fatal }
            throw error
        }

        if let fatal = fatalBox.first { throw fatal }
        if let streamFailure {
            throw CLIError(errorDescription: "\(streamFailure); partial recording saved to \(outputURL.path)")
        }
    }

    static func detectSDK(adb: Adb, serial: String) -> Int {
        guard let result = try? adb.shell(serial: serial, args: ["getprop", "ro.build.version.sdk"]) else {
            return 30
        }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 30
    }

    static func detectSize(adb: Adb, serial: String) -> (width: Int, height: Int)? {
        guard let result = try? adb.shell(serial: serial, args: ["wm", "size"]) else {
            return nil
        }
        return parseWMSize(result.stdout)
    }

    /// Scale a detected display size, rounding down to even dimensions
    /// (required by most H.264 encoders).
    static func scaledSize(_ size: (width: Int, height: Int), scale: Double) -> (width: Int, height: Int) {
        let width = max(2, Int(Double(size.width) * scale))
        let height = max(2, Int(Double(size.height) * scale))
        return (width - (width % 2), height - (height % 2))
    }

    /// Parse `adb shell wm size` output. Prefers the `Override size:` line
    /// (an active resolution override) over `Physical size:`.
    static func parseWMSize(_ output: String) -> (width: Int, height: Int)? {
        func size(from line: Substring) -> (Int, Int)? {
            guard let colon = line.lastIndex(of: ":") else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let parts = value.split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
            return (w, h)
        }
        let lines = output.split(separator: "\n")
        if let override = lines.first(where: { $0.contains("Override size:") }), let parsed = size(from: override) {
            return parsed
        }
        if let physical = lines.first(where: { $0.contains("Physical size:") }), let parsed = size(from: physical) {
            return parsed
        }
        return nil
    }

    /// Debug override for screenrecord's per-invocation time limit
    /// (`SIM_USE_SCREENRECORD_TIME_LIMIT`, seconds). API ≥ 34 devices
    /// stream unlimited (`--time-limit 0`), so the segment-restart path
    /// never fires naturally there — this forces short segments so tests
    /// and manual runs can exercise restarts without an API < 34 device.
    static func screenrecordTimeLimitOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        guard let raw = environment["SIM_USE_SCREENRECORD_TIME_LIMIT"],
              let value = Int(raw), value > 0 else {
            return nil
        }
        return value
    }

    /// Build the `adb screenrecord` argument vector. `--time-limit 0`
    /// (unlimited) is only valid on API ≥ 34; older devices hard-cap at 180 s,
    /// which the segment loop handles by restarting.
    static func screenrecordArguments(serial: String, sdk: Int, bitrate: Int?, size: (width: Int, height: Int)?, timeLimitOverride: Int? = nil) -> [String] {
        var arguments = ["-s", serial, "exec-out", "screenrecord", "--output-format=h264"]
        if let timeLimitOverride {
            arguments.append(contentsOf: ["--time-limit", "\(timeLimitOverride)"])
        } else if sdk >= 34 {
            arguments.append(contentsOf: ["--time-limit", "0"])
        }
        if let bitrate {
            arguments.append(contentsOf: ["--bit-rate", "\(bitrate)"])
        }
        if let size {
            arguments.append(contentsOf: ["--size", "\(size.width)x\(size.height)"])
        }
        arguments.append("-")
        return arguments
    }

    /// Legacy screencap-per-frame recorder, retained as an automatic fallback
    /// for when `screenrecord --output-format=h264` is unavailable. Caps
    /// around 7–8 FPS on a typical emulator (PNG transfer dominates).
    private static func recordVideoAndroidScreencapLegacy(
        adb: Adb,
        serial: String,
        outputURL: URL,
        fps: Int,
        quality: Int,
        scale: Double,
        cancellationFlag: CancellationFlag
    ) async throws {
        let adbPath = adb.binaryPath

        let initialFrameData = try captureAndroidScreencap(adbPath: adbPath, serial: serial)
        guard let initialImage = VideoFrameUtilities.makeCGImage(from: initialFrameData) else {
            throw CLIError(errorDescription: "Failed to decode initial Android screencap PNG")
        }

        let dimensions = VideoFrameUtilities.computeDimensions(for: initialImage, scale: scale)
        let recorder = try H264StreamRecorder(
            outputURL: outputURL,
            width: dimensions.width,
            height: dimensions.height,
            fps: fps,
            quality: quality
        )
        defer { recorder.invalidate() }

        let frameInterval = 1.0 / Double(fps)
        var frameCount: Int64 = 1
        var lastLogFrame: Int64 = 0
        let startTime = Date()
        var lastPresentationTime = CMTime.zero

        try recorder.append(image: initialImage, presentationTime: .zero)
        let writerStartTime = Date()

        while true {
            if Task.isCancelled || cancellationFlag.isCancelled() {
                break
            }

            let frameStart = Date()

            do {
                let frameData = try captureAndroidScreencap(adbPath: adbPath, serial: serial)
                guard let cgImage = VideoFrameUtilities.makeCGImage(from: frameData) else {
                    FileHandle.standardError.write(Data("Unable to decode screencap frame\n".utf8))
                    continue
                }

                let now = Date()
                var presentationTime = CMTime(seconds: now.timeIntervalSince(writerStartTime), preferredTimescale: 600)
                if presentationTime <= lastPresentationTime {
                    presentationTime = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 600))
                }

                try recorder.append(image: cgImage, presentationTime: presentationTime)
                lastPresentationTime = presentationTime
                frameCount += 1

                if frameCount - lastLogFrame >= Int64(fps) {
                    lastLogFrame = frameCount
                    let elapsed = Date().timeIntervalSince(startTime)
                    let actualFPS = Double(frameCount) / max(elapsed, 0.0001)
                    FileHandle.standardError.write(Data(String(format: "Captured %lld frames (%.1f FPS actual)\n", frameCount, actualFPS).utf8))
                }
            } catch let error as VideoWriterStallError {
                // A stalled writer does not recover; abort the recording
                // instead of re-logging the stall once per timeout forever.
                throw error
            } catch {
                FileHandle.standardError.write(Data("Error capturing frame: \(error.localizedDescription)\n".utf8))
            }

            let elapsed = Date().timeIntervalSince(frameStart)
            let sleepTime = frameInterval - elapsed
            if sleepTime > 0 {
                try await cancellableSleep(seconds: sleepTime, flag: cancellationFlag)
            }
        }

        try await recorder.finish()
    }

    /// `adb -s <serial> exec-out screencap -p` → PNG bytes. Uses a fresh
    /// `Process` per frame; the fork cost (~10 ms) is dwarfed by screencap
    /// itself (~120 ms median on a typical emulator) so a daemon-style
    /// persistent shell is unnecessary at this stage. Binary-safe: we read
    /// the pipe as raw `Data`, not via the `String`-typed `Adb.run()`.
    ///
    /// TODO(persistent-screencap-pipe): if frame budget tightens (e.g.
    /// a higher-FPS recording mode), replace this fork-per-frame with a
    /// single long-lived `adb shell` that pipes `screencap -p` repeatedly
    /// — amortises the ~10 ms fork across every frame. Out of scope
    /// while the screencap itself is the dominant cost; raising this
    /// TODO is the cheaper performance lever to reach for first when
    /// the frame loop becomes the bottleneck.
    static func captureAndroidScreencap(adbPath: String, serial: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", serial, "exec-out", "screencap", "-p"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let pngData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errMessage = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
            throw CLIError(errorDescription: "adb screencap exited \(process.terminationStatus): \(errMessage)")
        }
        guard !pngData.isEmpty else {
            throw CLIError(errorDescription: "adb screencap returned empty output")
        }
        return pngData
    }
}
