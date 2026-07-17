// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import AVFoundation
import SimUseCore

/// iOS Simulator backend for the `record-video` verb. Recording drives
/// `FBSimulatorVideoStream` in eager (fixed-rate) H.264 mode and muxes the
/// resulting Annex-B elementary stream straight into an MP4 (passthrough, no
/// re-encode). Because the stream carries no timestamps, presentation times
/// are laid out as a constant frame rate (`--fps`) — this is what makes the
/// requested frame rate honorable and keeps playback smooth (an eager
/// stream's bytes arrive in bursts, so deriving PTS from arrival time would
/// judder).
///
/// idb's lazy (damage-driven) mode is unused: it emits no frames on the
/// modern Metal-backed simulator surface even during motion.
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

    /// Raised only when the H.264 video stream cannot be set up (private
    /// CoreSimulator API unavailable, stream fails to start). Triggers the
    /// screenshot-capture fallback; mid-recording failures propagate as-is.
    private struct StreamUnavailableError: Error {
        let underlying: String
    }

    @OptionGroup public var device: DeviceOptions

    @Option(help: "Frames per second (1-60, default: 30).")
    public var fps: Int?

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

    public static func validateOptions(fps: Int?, quality: Int, scale: Double) throws {
        if let fps {
            guard fps >= 1 && fps <= 60 else {
                throw ValidationError("FPS must be between 1 and 60")
            }
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
            try await recordVideoViaStream(
                simulator: targetSimulator,
                outputURL: outputURL,
                fps: fps ?? 30,
                quality: quality,
                scale: scale,
                cancellationFlag: cancellationFlag
            )
            recordingFinished.cancel()
            return ExecutionResult(path: outputURL.path)
        } catch let unavailable as StreamUnavailableError {
            FileHandle.standardError.write(Data("warning: H.264 stream unavailable (\(unavailable.underlying)); falling back to screenshot capture\n".utf8))
            do {
                try await recordVideoViaScreenshots(
                    simulator: targetSimulator,
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

    // MARK: - H.264 stream recording

    private func recordVideoViaStream(
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
        let bitrate = H264StreamRecorder.estimateBitrate(
            width: dimensions.width,
            height: dimensions.height,
            fps: fps,
            quality: quality
        )

        // Constant-rate PTS layout — the eager stream is fixed-rate, so lay
        // frames out at exactly 1/fps to keep playback smooth regardless of
        // when the encoded bytes happen to arrive.
        let recorder = try H264PassthroughRecorder(outputURL: outputURL, frameRate: fps)
        var recorderFinalized = false
        defer { if !recorderFinalized { recorder.invalidate() } }

        let streamError = FirstErrorBox()
        let pipeline = H264MuxingPipeline(recorder: recorder, onFatalError: { error in
            streamError.set(error)
            cancellationFlag.cancel()
        })
        let consumer = PipelineDataConsumer(pipeline: pipeline)

        let config = FBVideoStreamConfiguration(
            encoding: .H264,
            framesPerSecond: NSNumber(value: fps),
            compressionQuality: NSNumber(value: Double(quality) / 100.0),
            scaleFactor: scale < 1.0 ? NSNumber(value: scale) : nil,
            avgBitrate: NSNumber(value: bitrate),
            keyFrameRate: NSNumber(value: 2)
        )

        let videoStream: FBVideoStream
        do {
            videoStream = try await FutureBridge.value(simulator.createStream(with: config))
        } catch {
            throw StreamUnavailableError(underlying: error.localizedDescription)
        }

        let startFuture = videoStream.startStreaming(consumer)
        startFuture.onQueue(BridgeQueues.videoStreamQueue, notifyOfCompletion: { future in
            if let error = future.error {
                streamError.set(error)
            }
        })
        videoStream.completed.onQueue(BridgeQueues.videoStreamQueue, notifyOfCompletion: { future in
            if let error = future.error {
                streamError.set(error)
            }
        })

        // Give the stream a moment to fail fast on an attach error before we
        // commit to it — a failure here means H.264 streaming is unavailable.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        if let error = streamError.first, !pipeline.firstFrameReceived {
            throw StreamUnavailableError(underlying: (error as NSError).localizedDescription)
        }

        try await runStreamPollLoop(pipeline: pipeline, streamError: streamError, cancellationFlag: cancellationFlag)

        // Finalize the MP4 before stopping the stream: the moov atom must be
        // written before a supervisor's post-signal SIGKILL can land.
        pipeline.finishIngest()
        do {
            try await recorder.finish(stopHostTime: ProcessInfo.processInfo.systemUptime)
            recorderFinalized = true
        } catch {
            if let streamErr = streamError.first { throw streamErr }
            throw error
        }

        await stopStreamBestEffort(videoStream)

        if let error = streamError.first {
            throw error
        }
    }

    private func runStreamPollLoop(
        pipeline: H264MuxingPipeline,
        streamError: FirstErrorBox,
        cancellationFlag: CancellationFlag
    ) async throws {
        let startTime = Date()
        var lastProgress = startTime
        var warnedNoFrames = false

        while true {
            if Task.isCancelled || cancellationFlag.isCancelled() { break }
            if streamError.first != nil { break }

            let now = Date()
            if !warnedNoFrames, !pipeline.firstFrameReceived, now.timeIntervalSince(startTime) > 3 {
                warnedNoFrames = true
                FileHandle.standardError.write(Data("warning: no video frames received yet\n".utf8))
            }
            if now.timeIntervalSince(lastProgress) >= 2 {
                lastProgress = now
                FileHandle.standardError.write(Data(String(format: "Captured %lld frames\n", pipeline.framesWritten).utf8))
            }
            try? await cancellableSleep(seconds: 0.1, flag: cancellationFlag)
        }
    }

    /// Stop the stream, waiting at most ~1 s. The MP4 is already finalized,
    /// so this only politely releases the simulator's encoder.
    private func stopStreamBestEffort(_ videoStream: FBVideoStream) async {
        let once = OnceFlag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = { if once.trySet() { continuation.resume() } }
            BridgeQueues.videoStreamQueue.async {
                videoStream.stopStreaming().onQueue(BridgeQueues.videoStreamQueue, notifyOfCompletion: { _ in resume() })
            }
            BridgeQueues.videoStreamQueue.asyncAfter(deadline: .now() + 1.0) { resume() }
        }
    }

    // MARK: - Screenshot fallback

    /// Last-resort recorder used only when the H.264 stream API is
    /// unavailable (e.g. after an Xcode update breaks the private
    /// CoreSimulator surface). Polls screenshots and re-encodes through
    /// `H264StreamRecorder`; caps near ~8-10 fps.
    private func recordVideoViaScreenshots(
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

        var lastPresentationTime = CMTime.zero
        let frameInterval = 1.0 / Double(fps)
        try recorder.append(image: initialImage, presentationTime: .zero)
        let writerStartTime = Date()

        while true {
            if Task.isCancelled || cancellationFlag.isCancelled() { break }
            let frameStart = Date()

            do {
                let frameData = try await VideoFrameUtilities.captureScreenshotData(from: simulator)
                if let cgImage = VideoFrameUtilities.makeCGImage(from: frameData) {
                    let now = Date()
                    var presentationTime = CMTime(seconds: now.timeIntervalSince(writerStartTime), preferredTimescale: 600)
                    if presentationTime <= lastPresentationTime {
                        presentationTime = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 600))
                    }
                    try recorder.append(image: cgImage, presentationTime: presentationTime)
                    lastPresentationTime = presentationTime
                }
            } catch let error as VideoWriterStallError {
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

/// Bridges `FBSimulatorVideoStream`'s H.264 byte callbacks into the shared
/// muxing pipeline. Not a `FBDataConsumerSync`, so the passed data is
/// heap-backed and safe to hand to the pipeline synchronously.
private final class PipelineDataConsumer: NSObject, FBDataConsumer {
    private let pipeline: H264MuxingPipeline

    init(pipeline: H264MuxingPipeline) {
        self.pipeline = pipeline
    }

    func consumeData(_ data: Data) {
        pipeline.ingest(data)
    }

    func consumeEndOfFile() {
        pipeline.finishIngest()
    }
}
