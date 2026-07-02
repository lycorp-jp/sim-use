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
///   * `IOSSimRecordVideoCommand.execute()` for iOS Simulator UDIDs.
///   * an inline Android orchestrator that drives `adb exec-out
///     screencap -p` and feeds the PNG frames into the same
///     `H264StreamRecorder` the iOS path uses.
///
/// The Android branch lives inline (rather than in an
/// `AndroidRecordVideoCommand` peer) because it cross-cuts
/// AndroidBackend (for `Adb`) and iOSSimBackend (for
/// `H264StreamRecorder` / `VideoFrameUtilities`). Only SimUse — the
/// executable target — depends on both modules, so this is the only
/// place where the orchestration can live without dragging
/// iOSSimBackend into AndroidBackend's dep cone.
struct RecordVideo: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimRecordVideoCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        commandName: "record-video",
        abstract: "Record the simulator display to an MP4 file using H.264 encoding"
    )

    @OptionGroup var device: DeviceOptions

    @Option(help: "Frames per second (1-30, default: 10)")
    var fps: Int = 10

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
        var sub = IOSSimRecordVideoCommand()
        sub.fps = fps
        sub.quality = quality
        sub.scale = scale
        sub.output = output
        sub.device = device
        sub.json = json
        return try await sub.execute()
    }

    // MARK: - Android

    /// Android dispatch: drives a tight `adb exec-out screencap -p`
    /// loop and feeds each PNG frame into the same
    /// `H264StreamRecorder` used by the iOS path. Empirically caps
    /// around 7–8 FPS on a typical emulator (PNG transfer dominates).
    ///
    /// Important: the bridge `/screenshot` path is NOT used here.
    /// That route goes through `AccessibilityService.takeScreenshot`
    /// which the Android framework rate-limits to ~2 FPS — unusable
    /// for video.
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
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if !recordingFinished.isCancelled() {
                    _exit(0)
                }
            }
        }
        defer { signalObserver.invalidate() }

        do {
            try await recordVideoAndroid(
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

    private func recordVideoAndroid(
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