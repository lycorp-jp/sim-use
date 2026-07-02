// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import AVFoundation
import SimUseCore

/// iOS Simulator backend for the `record-video` verb. The top-level
/// cross-platform `record-video` forwards iOS UDIDs through here; the
/// Android branch keeps its execute body inline in the forwarder
/// because it cross-cuts AndroidBackend (for `Adb`) and iOSSimBackend
/// (for `H264StreamRecorder` / `VideoFrameUtilities`). Only SimUse —
/// the executable target — depends on both, so AndroidBackend cannot
/// host the Android record-video orchestrator without dragging
/// iOSSimBackend into its dep cone.
public struct IOSSimRecordVideoCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "record-video",
        abstract: "Record the iOS Simulator display to an MP4 file using H.264 encoding"
    )

    public struct ExecutionResult: Codable {
        public let path: String
        public init(path: String) {
            self.path = path
        }
    }

    @OptionGroup public var device: DeviceOptions

    @Option(help: "Frames per second (1-30, default: 10)")
    public var fps: Int = 10

    @Option(help: "Quality factor (1-100) controlling bitrate (default: 80)")
    public var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0, default: 1.0)")
    public var scale: Double = 1.0

    @Option(help: "Output MP4 file path. Defaults to sim-use-video-<timestamp>.mp4 in the current directory.")
    public var output: String?

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public var daemonBypass: Bool { true }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(
            stdout: result.path + "\n",
            stderr: "Recording saved to \(result.path)\n"
        )
    }

    public func validate() throws {
        try Self.validateOptions(fps: fps, quality: quality, scale: scale)
    }

    public static func validateOptions(fps: Int, quality: Int, scale: Double) throws {
        guard fps >= 1 && fps <= 30 else {
            throw ValidationError("FPS must be between 1 and 30")
        }
        guard quality >= 1 && quality <= 100 else {
            throw ValidationError("Quality must be between 1 and 100")
        }
        guard scale >= 0.1 && scale <= 1.0 else {
            throw ValidationError("Scale must be between 0.1 and 1.0")
        }
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let trimmedUDID = device.resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUDID.isEmpty else {
            throw CLIError(errorDescription: "Simulator UDID cannot be empty. Use --udid to specify a simulator.")
        }

        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        guard let targetSimulator = simulatorSet.allSimulators.first(where: { $0.udid == trimmedUDID }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(trimmedUDID) not found.")
        }

        guard targetSimulator.state == .booted else {
            let stateDescription = FBiOSTargetStateStringFromState(targetSimulator.state)
            throw CLIError(errorDescription: "Simulator \(trimmedUDID) is not booted. Current state: \(stateDescription)")
        }

        let outputURL = try Self.prepareOutputURL(output: output)
        FileHandle.standardError.write(Data("Recording simulator \(targetSimulator.udid) to \(outputURL.path)\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop recording\n".utf8))

        let cancellationFlag = CancellationFlag()
        let recordingFinished = CancellationFlag()
        let signalObserver = SignalObserver(signals: [SIGINT, SIGTERM]) {
            cancellationFlag.cancel()
            RecordingFinishWatchdog.arm(recordingFinished: recordingFinished)
        }
        defer { signalObserver.invalidate() }

        do {
            try await recordVideo(
                simulator: targetSimulator,
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

    private func recordVideo(
        simulator: FBSimulator,
        outputURL: URL,
        fps: Int,
        quality: Int,
        scale: Double,
        cancellationFlag: CancellationFlag
    ) async throws {
        let initialFrameData = try await VideoFrameUtilities.captureScreenshotData(from: simulator)
        guard let initialImage = VideoFrameUtilities.makeCGImage(from: initialFrameData) else {
            throw CLIError(errorDescription: "Failed to decode simulator screenshot")
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
            if Task.isCancelled {
                break
            }
            if cancellationFlag.isCancelled() {
                break
            }

            let frameStart = Date()

            do {
                let frameData = try await VideoFrameUtilities.captureScreenshotData(from: simulator)
                // A decode failure must still fall through to the
                // frame-pacing sleep below — `continue` here would
                // hot-spin the loop for as long as decoding keeps
                // failing.
                if let cgImage = VideoFrameUtilities.makeCGImage(from: frameData) {
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
                } else {
                    FileHandle.standardError.write(Data("Unable to decode screenshot frame\n".utf8))
                }
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

    /// Resolve the user-supplied `--output` argument into a concrete
    /// MP4 file URL. Public so the cross-platform forwarder's Android
    /// branch can reuse the same path semantics.
    public static func prepareOutputURL(output: String?) throws -> URL {
        let fileManager = FileManager.default
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let providedPath = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath: String
        if let providedPath, !providedPath.isEmpty {
            resolvedPath = (providedPath as NSString).expandingTildeInPath
        } else {
            resolvedPath = "sim-use-video-\(formatter.string(from: Date())).mp4"
        }

        let baseURL: URL
        if resolvedPath.hasPrefix("/") {
            baseURL = URL(fileURLWithPath: resolvedPath)
        } else {
            baseURL = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(resolvedPath)
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: baseURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let filename = "sim-use-video-\(formatter.string(from: Date())).mp4"
            let directoryURL = baseURL
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            }
            return directoryURL.appendingPathComponent(filename)
        }

        let directoryURL = baseURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        if fileManager.fileExists(atPath: baseURL.path) {
            var existingIsDirectory: ObjCBool = false
            fileManager.fileExists(atPath: baseURL.path, isDirectory: &existingIsDirectory)
            if existingIsDirectory.boolValue {
                throw CLIError(errorDescription: "Output path \(baseURL.path) is a directory. Provide a file name or point to a different location.")
            }
            try fileManager.removeItem(at: baseURL)
        }

        return baseURL
    }
}