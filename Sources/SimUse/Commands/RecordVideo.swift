// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import AVFoundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `record-video` verb. Owns the flag
/// surface and resolves the target platform, then delegates to:
///
///   * `IOSSimRecordVideoCommand.execute()` for iOS Simulator UDIDs
///     (which drives `FBSimulatorVideoStream` eager H.264 at `--fps`).
///   * an inline Android orchestrator that streams `adb exec-out
///     screenrecord --output-format=h264` into the shared H.264 →
///     MP4 passthrough muxer (`H264MuxingPipeline`).
///
/// The Android branch lives inline (rather than in an
/// `AndroidRecordVideoCommand` peer) because it cross-cuts
/// AndroidBackend (for `Adb` / `AdbStreamingProcess`) and iOSSimBackend
/// (for the AVFoundation muxer). Only SimUse — the executable target —
/// depends on both modules, so this is the only place where the
/// orchestration can live without dragging iOSSimBackend into
/// AndroidBackend's dep cone.
struct RecordVideo: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimRecordVideoCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        commandName: "record-video",
        abstract: "Record the simulator display to an MP4 file using H.264 encoding"
    )

    @OptionGroup var device: DeviceOptions

    @Option(help: "Frames per second (1-60, default: 30). Ignored on Android (screenrecord uses the device's native variable frame rate).")
    var fps: Int?

    @Option(help: "Quality factor (1-100) controlling bitrate (default: 80)")
    var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0, default: 1.0)")
    var scale: Double = 1.0

    @Option(help: "Output MP4 file path. Defaults to sim-use-video-<timestamp>.mp4 in the current directory.")
    var output: String?

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    var daemonBypass: Bool { true }

    func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(
            stdout: result.path + "\n",
            stderr: "Recording saved to \(result.path)\n"
        )
    }

    func validate() throws {
        try IOSSimRecordVideoCommand.validateOptions(fps: fps, quality: quality, scale: scale)
    }

    func execute() async throws -> ExecutionResult {
        switch PlatformRouter.resolve(udid: device.resolved) {
        case .android:
            return try await executeAndroid()
        case .iOSSim, .none:
            return try await executeIOSSim()
        }
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        let sub = makeIOSSubcommand()
        return try await sub.execute()
    }

    /// Construct the backend command and copy every parsed flag across.
    /// A missed field stays in ArgumentParser's wrapper-definition state
    /// and traps on first read (#42) — pinned by
    /// `ForwarderInitializationGuardTests`.
    func makeIOSSubcommand() -> IOSSimRecordVideoCommand {
        var sub = IOSSimRecordVideoCommand()
        sub.fps = fps
        sub.quality = quality
        sub.scale = scale
        sub.output = output
        sub.device = device
        sub.json = json
        return sub
    }

    // MARK: - Android

    /// Raised only when `adb screenrecord` cannot produce an H.264 stream
    /// (unsupported args, encoder unavailable). Triggers the legacy
    /// screencap-frame fallback; mid-recording failures propagate as-is.
    private struct ScreenrecordUnavailableError: Error {
        let underlying: String
    }

    /// Android dispatch: pipes `adb exec-out screenrecord
    /// --output-format=h264 -` into the shared H.264 muxer for native,
    /// variable-frame-rate capture. Falls back to the legacy
    /// `screencap`-per-frame loop (≈7–8 FPS) only if screenrecord cannot
    /// start.
    ///
    /// The bridge `/screenshot` path is NOT used: it goes through
    /// `AccessibilityService.takeScreenshot`, which the Android framework
    /// rate-limits to ~2 FPS — unusable for video.
    private func executeAndroid() async throws -> ExecutionResult {
        let adb = Adb()
        let serial = device.resolved
        try assertAdbDeviceOnline(adb: adb, serial: serial)

        let outputURL = try IOSSimRecordVideoCommand.prepareOutputURL(output: output)
        FileHandle.standardError.write(Data("Recording Android device \(serial) to \(outputURL.path)\n".utf8))
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
                outputURL: outputURL,
                fps: fps,
                quality: quality,
                scale: scale,
                cancellationFlag: cancellationFlag
            )
            recordingFinished.cancel()
            return ExecutionResult(path: outputURL.path)
        } catch let unavailable as ScreenrecordUnavailableError {
            FileHandle.standardError.write(Data("warning: screenrecord unavailable (\(unavailable.underlying)); falling back to screencap frames\n".utf8))
            do {
                try await recordVideoAndroidScreencapLegacy(
                    adb: adb,
                    serial: serial,
                    outputURL: outputURL,
                    fps: fps ?? 10,
                    quality: quality,
                    scale: scale,
                    cancellationFlag: cancellationFlag
                )
                recordingFinished.cancel()
                return ExecutionResult(path: outputURL.path)
            } catch {
                recordingFinished.cancel()
                throw CLIError(errorDescription: "Failed to record video: \(error.localizedDescription)")
            }
        } catch {
            recordingFinished.cancel()
            throw CLIError(errorDescription: "Failed to record video: \(error.localizedDescription)")
        }
    }

    private func assertAdbDeviceOnline(adb: Adb, serial: String) throws {
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
    private func recordVideoAndroidStream(
        adb: Adb,
        serial: String,
        outputURL: URL,
        fps: Int?,
        quality: Int,
        scale: Double,
        cancellationFlag: CancellationFlag
    ) async throws {
        if fps != nil {
            FileHandle.standardError.write(Data("note: --fps is ignored on Android (screenrecord records at native variable frame rate)\n".utf8))
        }

        let sdk = Self.detectSDK(adb: adb, serial: serial)
        let size = scale < 1.0 ? Self.detectScaledSize(adb: adb, serial: serial, scale: scale) : nil
        let bitrate = size.map { H264StreamRecorder.estimateBitrate(width: $0.width, height: $0.height, fps: 30, quality: quality) }
        let arguments = Self.screenrecordArguments(serial: serial, sdk: sdk, bitrate: bitrate, size: size)

        let recorder = try H264PassthroughRecorder(outputURL: outputURL)
        var recorderFinalized = false
        defer { if !recorderFinalized { recorder.invalidate() } }

        let fatalBox = FirstErrorBox()
        let pipeline = H264MuxingPipeline(recorder: recorder, onFatalError: { error in
            fatalBox.set(error)
            cancellationFlag.cancel()
        })

        var firstSegment = true
        var disconnected = false

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

            // The process exited on its own — either the API-level time limit
            // was reached (restart to continue) or the device stopped feeding.
            let exitCode = process.waitForExit(timeout: 2)
            let bytesThisSegment = process.stdoutByteCount - segmentStartBytes
            if bytesThisSegment == 0 {
                if !pipeline.firstFrameReceived {
                    let exitDescription = exitCode.map(String.init) ?? "timeout"
                    throw ScreenrecordUnavailableError(
                        underlying: "screenrecord produced no output (exit \(exitDescription)): \(process.collectedStderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                    )
                }
                disconnected = true
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
        if disconnected {
            throw CLIError(errorDescription: "Android device stopped producing frames during recording; partial recording saved to \(outputURL.path)")
        }
    }

    private static func detectSDK(adb: Adb, serial: String) -> Int {
        guard let result = try? adb.shell(serial: serial, args: ["getprop", "ro.build.version.sdk"]) else {
            return 30
        }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 30
    }

    private static func detectScaledSize(adb: Adb, serial: String, scale: Double) -> (width: Int, height: Int)? {
        guard let result = try? adb.shell(serial: serial, args: ["wm", "size"]),
              let base = parseWMSize(result.stdout) else {
            return nil
        }
        let width = max(2, Int(Double(base.width) * scale))
        let height = max(2, Int(Double(base.height) * scale))
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

    /// Build the `adb screenrecord` argument vector. `--time-limit 0`
    /// (unlimited) is only valid on API ≥ 34; older devices hard-cap at 180 s,
    /// which the segment loop handles by restarting.
    static func screenrecordArguments(serial: String, sdk: Int, bitrate: Int?, size: (width: Int, height: Int)?) -> [String] {
        var arguments = ["-s", serial, "exec-out", "screenrecord", "--output-format=h264"]
        if sdk >= 34 {
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
    private func recordVideoAndroidScreencapLegacy(
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
    private func captureAndroidScreencap(adbPath: String, serial: String) throws -> Data {
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