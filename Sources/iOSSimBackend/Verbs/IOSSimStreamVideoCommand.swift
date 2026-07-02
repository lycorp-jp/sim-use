// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import SimUseCore

/// iOS Simulator backend for the `stream-video` verb. iOS-only — no
/// Android peer. The Android path used to fail-fast with a redirect
/// to `record-video`; with path B the entire verb only exists under
/// `sim-use ios stream-video`, so an Android caller never reaches
/// this code path in the first place.
public struct IOSSimStreamVideoCommand: SimUseExecutableCommand {
    public enum OutputFormat: String, ExpressibleByArgument, Codable, Sendable {
        case mjpeg
        case raw
        case ffmpeg
        case bgra
    }

    /// Summary of a completed stream run. The actual video bytes are
    /// written to stdout inline during `execute()` — they are a side
    /// channel, not part of the Result. Streaming commands bypass the
    /// daemon transport for exactly this reason, but the typed Result
    /// still powers a future `--json` flag that emits the summary alone.
    public struct ExecutionResult: Codable {
        public let framesStreamed: UInt64
        public let durationSeconds: Double
        public let format: OutputFormat

        public init(framesStreamed: UInt64, durationSeconds: Double, format: OutputFormat) {
            self.framesStreamed = framesStreamed
            self.durationSeconds = durationSeconds
            self.format = format
        }
    }

    public static let configuration = CommandConfiguration(
        commandName: "stream-video",
        abstract: "Stream simulator frames to stdout using screenshot capture"
    )

    @OptionGroup public var device: DeviceOptions

    @Option(help: "Output format: mjpeg, raw, ffmpeg, bgra (default: mjpeg; bgra is experimental: no frame count is reported)")
    public var format: OutputFormat = .mjpeg

    @Option(help: "Frames per second (1-30, default: 10)")
    public var fps: Int = 10

    @Option(help: "JPEG quality (1-100, default: 80)")
    public var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0, default: 1.0)")
    public var scale: Double = 1.0

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        if let arg = try DeviceOptions.selectExplicit(device: device.device, udid: device.udid),
           PlatformRouter.looksLikeAndroid(arg) {
            // CLIError so the message survives our run() catch — see
            // IOSSimKeyCommand for the rationale.
            throw CLIError(errorDescription: "stream-video is iOS-only. On Android, use `sim-use record-video --udid \(arg)` to capture an MP4 instead.")
        }
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public var daemonBypass: Bool { true }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        guard result.framesStreamed > 0, result.durationSeconds > 0 else {
            return .empty
        }
        let avgFPS = Double(result.framesStreamed) / result.durationSeconds
        let line = String(
            format: "Streamed %llu frames in %.1f seconds (%.1f FPS average)\n",
            result.framesStreamed,
            result.durationSeconds,
            avgFPS
        )
        return CommandOutput(stderr: line)
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

        let cancellationFlag = CancellationFlag()
        let signalObserver = SignalObserver(signals: [SIGINT, SIGTERM]) {
            cancellationFlag.cancel()
        }
        defer { signalObserver.invalidate() }

        switch format {
        case .bgra:
            try await streamBGRA(to: targetSimulator, cancellationFlag: cancellationFlag)
            // BGRA path drives streaming via FBVideoStream and does not track
            // frame counts; return a zero-summary so `format(_:)` emits nothing.
            return ExecutionResult(framesStreamed: 0, durationSeconds: 0, format: format)
        default:
            return try await streamCompressedFrames(from: targetSimulator, format: format, cancellationFlag: cancellationFlag)
        }
    }

    // MARK: - Screenshot-based streaming

    private func streamCompressedFrames(
        from simulator: FBSimulator,
        format: OutputFormat,
        cancellationFlag: CancellationFlag
    ) async throws -> ExecutionResult {
        FileHandle.standardError.write(Data("Starting screenshot-based video stream from simulator \(simulator.udid)...\n".utf8))
        FileHandle.standardError.write(Data("Format: \(format.rawValue), FPS: \(fps), Quality: \(quality), Scale: \(scale)\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop streaming\n".utf8))

        let frameInterval = 1.0 / Double(fps)
        let mjpegBoundary = "--mjpegstream"
        let destination = FileHandle.standardOutput

        if format == .mjpeg {
            let header = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=\(mjpegBoundary)\r\n\r\n"
            destination.write(Data(header.utf8))
        }

        var frameCount: UInt64 = 0
        let startTime = Date()

        while true {
            if Task.isCancelled {
                break
            }
            if cancellationFlag.isCancelled() {
                break
            }

            let frameStartTime = Date()

            do {
                let screenshotData = try await VideoFrameUtilities.captureScreenshotData(from: simulator)
                let processedData = try await VideoFrameUtilities.processJPEGData(screenshotData, scale: scale, quality: quality)

                switch format {
                case .mjpeg:
                    let frameHeader = "\(mjpegBoundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(processedData.count)\r\n\r\n"
                    destination.write(Data(frameHeader.utf8))
                    destination.write(processedData)
                    destination.write(Data("\r\n".utf8))
                case .raw:
                    var length = UInt32(processedData.count).bigEndian
                    destination.write(Data(bytes: &length, count: 4))
                    destination.write(processedData)
                case .ffmpeg:
                    destination.write(processedData)
                case .bgra:
                    break
                }

                frameCount += 1

                if frameCount % UInt64(max(1, fps)) == 0 {
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed > 0 {
                        let actualFPS = Double(frameCount) / elapsed
                        FileHandle.standardError.write(Data(String(format: "Captured %llu frames (%.1f FPS actual)\n", frameCount, actualFPS).utf8))
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("Error capturing frame: \(error.localizedDescription)\n".utf8))
            }

            let elapsed = Date().timeIntervalSince(frameStartTime)
            let sleepTime = frameInterval - elapsed
            if sleepTime > 0 {
                try? await cancellableSleep(seconds: sleepTime, flag: cancellationFlag)
            }
        }

        if format == .mjpeg {
            destination.write(Data("\(mjpegBoundary)--\r\n".utf8))
        }

        let elapsed = Date().timeIntervalSince(startTime)
        return ExecutionResult(framesStreamed: frameCount, durationSeconds: elapsed, format: format)
    }

    // MARK: - Legacy BGRA streaming

    private func streamBGRA(
        to simulator: FBSimulator,
        cancellationFlag: CancellationFlag
    ) async throws {
        FileHandle.standardError.write(Data("Starting BGRA video stream from simulator \(simulator.udid)...\n".utf8))
        FileHandle.standardError.write(Data("Format: bgra, Quality: \(quality), Scale: \(scale)\n".utf8))
        FileHandle.standardError.write(Data("Note: This is raw pixel data. Use ffmpeg to convert:\n".utf8))
        FileHandle.standardError.write(Data("  sim-use ios stream-video --format bgra --udid <UDID> | ffmpeg -f rawvideo -pixel_format bgra -video_size WIDTHxHEIGHT -i - output.mp4\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop streaming\n".utf8))

        do {
            let config = FBVideoStreamConfiguration(
                encoding: .BGRA,
                framesPerSecond: nil,
                compressionQuality: NSNumber(value: Double(quality) / 100.0),
                scaleFactor: NSNumber(value: scale),
                avgBitrate: nil,
                keyFrameRate: nil
            )

            let stdoutConsumer = FBFileWriter.syncWriter(withFileDescriptor: STDOUT_FILENO, closeOnEndOfFile: false)
            let videoStreamFuture = simulator.createStream(with: config)
            let videoStream = try await FutureBridge.value(videoStreamFuture)
            let startFuture = videoStream.startStreaming(stdoutConsumer)

            // The private startStreaming future can resolve with an error at
            // any point (attach failure during startup, or later), and the
            // operation's `completed` future is the mid-stream termination
            // channel. Neither has a continuation to resume — box the first
            // error and let the wait loop below pick it up, so failures
            // surface as a non-zero exit instead of a stderr line.
            let streamError = FirstErrorBox()
            startFuture.onQueue(BridgeQueues.videoStreamQueue, notifyOfCompletion: { future in
                if let error = future.error {
                    FileHandle.standardError.write(Data("Stream initialization error: \(error)\n".utf8))
                    streamError.set(error)
                }
            })
            videoStream.completed.onQueue(BridgeQueues.videoStreamQueue, notifyOfCompletion: { future in
                if let error = future.error {
                    FileHandle.standardError.write(Data("Stream terminated with error: \(error)\n".utf8))
                    streamError.set(error)
                }
            })

            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let error = streamError.first {
                throw error
            }
            FileHandle.standardError.write(Data("BGRA stream is now running...\n".utf8))

            while true {
                if Task.isCancelled {
                    break
                }
                if cancellationFlag.isCancelled() {
                    break
                }
                if streamError.first != nil {
                    break
                }
                try? await cancellableSleep(seconds: 0.1, flag: cancellationFlag)
            }

            // A dead stream cannot be stopped gracefully — stopStreaming on
            // it fails with a secondary error that would mask the original.
            if let error = streamError.first {
                throw error
            }

            FileHandle.standardError.write(Data("\nStopping BGRA stream...\n".utf8))
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                BridgeQueues.videoStreamQueue.async {
                    let stopFuture = videoStream.stopStreaming()
                    stopFuture.onQueue(BridgeQueues.videoStreamQueue, notifyOfCompletion: { future in
                        FileHandle.standardError.write(Data("BGRA stream stopped\n".utf8))
                        if let error = future.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: ())
                        }
                    })
                }
            }
        } catch {
            throw CLIError(errorDescription: "Failed to stream BGRA video: \(error.localizedDescription)")
        }
    }
}