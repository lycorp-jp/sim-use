// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import CompanionUtilities
import FBSimulatorControl
@preconcurrency import FBControlCore
import SimUseCore
import SimUseVideo

/// iOS Simulator backend for the `stream-video` verb. The top-level
/// cross-platform `StreamVideo` forwards iOS UDIDs here (#78); an
/// Android UDID passed directly to `sim-use ios stream-video` is
/// redirected to the surfaces that serve it.
public struct IOSSimStreamVideoCommand: SimUseExecutableCommand {
    public enum OutputFormat: String, ExpressibleByArgument, Codable, Sendable {
        case mjpeg
        case raw
        case ffmpeg
        case bgra

        /// The container this format's consumers can decode, or nil for
        /// `bgra`, which carries raw pixels rather than encoded frames.
        func frameContainer(quality: Int) -> FrameContainer? {
            switch self {
            // Motion JPEG is JPEG by definition and by consumer: ffmpeg's
            // `mpjpeg` demuxer rejects any other container.
            case .mjpeg: .jpeg(quality: quality)
            // `raw` delimits frames with its own length prefix, and the
            // documented `ffmpeg` pipeline sniffs the container
            // (`-f image2pipe`), so both carry the capture losslessly and
            // untranscoded.
            case .raw, .ffmpeg: .png
            case .bgra: nil
            }
        }
    }

    /// Summary of a completed stream run. The actual video bytes are
    /// written to stdout inline during `execute()` — they are a side
    /// channel, not part of the Result. Streaming commands bypass the
    /// daemon transport for exactly this reason, and `--json` is
    /// rejected in validate(): the envelope would be appended to the
    /// same stdout as the video bytes and corrupt the stream.
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

    @Option(help: "JPEG quality for mjpeg (1-100, default: 80). Ignored by raw/ffmpeg, which carry lossless PNG frames.")
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
            throw CLIError(errorDescription: "`sim-use ios stream-video` only drives iOS simulators. For Android, use `sim-use stream-video --udid \(arg)` (or `sim-use android stream-video`).")
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
        // stdout carries the raw video bytes; the JSON envelope would be
        // appended to the same stream after execute() and corrupt it.
        if json.enabled {
            throw ValidationError("--json is not available on stream-video: stdout carries the raw video bytes and the envelope would corrupt the stream. The run summary is printed to stderr instead.")
        }
        try VideoRecordingOptions.validateStreaming(fps: fps, quality: quality, scale: scale)
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
            guard let container = format.frameContainer(quality: quality) else {
                throw CLIError(errorDescription: "Format \(format.rawValue) does not carry encoded frames")
            }
            return try await streamCompressedFrames(
                from: targetSimulator,
                format: format,
                container: container,
                cancellationFlag: cancellationFlag
            )
        }
    }

    // MARK: - Screenshot-based streaming

    private func streamCompressedFrames(
        from simulator: FBSimulator,
        format: OutputFormat,
        container: FrameContainer,
        cancellationFlag: CancellationFlag
    ) async throws -> ExecutionResult {
        FileHandle.standardError.write(Data("Starting screenshot-based video stream from simulator \(simulator.udid)...\n".utf8))
        FileHandle.standardError.write(Data("Format: \(format.rawValue), FPS: \(fps), Frames: \(container), Scale: \(scale)\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop streaming\n".utf8))

        let frameSource = try await SimulatorFrameSource(simulator: simulator)
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
                let processedData = try VideoFrameUtilities.encodeFrame(
                    frameSource.currentFrame(),
                    as: container,
                    scale: scale
                )

                switch format {
                case .mjpeg:
                    let frameHeader = "\(mjpegBoundary)\r\nContent-Type: \(container.mimeType)\r\nContent-Length: \(processedData.count)\r\n\r\n"
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
                format: .bgra,
                framesPerSecond: nil,
                rateControl: .quality(Double(quality) / 100.0),
                scaleFactor: scale,
                keyFrameRate: nil
            )

            let stdoutConsumer = FBFileWriter.syncWriter(withFileDescriptor: STDOUT_FILENO, closeOnEndOfFile: false)
            // The stream comes back already running — attach failures throw
            // here instead of surfacing asynchronously.
            let videoStream = try await simulator.createStream(configuration: config, to: stdoutConsumer)
            FileHandle.standardError.write(Data("BGRA stream is now running...\n".utf8))

            // Mid-stream termination surfaces through awaitCompletion();
            // box the error and flip a flag so the cancellation-aware wait
            // loop below picks both up, and failures surface as a non-zero
            // exit instead of a stderr line.
            let streamError = FirstErrorBox()
            let streamEnded = CancellationFlag()
            let completionTask = Task {
                do {
                    try await videoStream.awaitCompletion()
                } catch {
                    FileHandle.standardError.write(Data("Stream terminated with error: \(error)\n".utf8))
                    streamError.set(error)
                }
                streamEnded.cancel()
            }

            while true {
                if Task.isCancelled {
                    break
                }
                if cancellationFlag.isCancelled() {
                    break
                }
                if streamEnded.isCancelled() {
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
            try await videoStream.stopStreaming()
            await completionTask.value
            FileHandle.standardError.write(Data("BGRA stream stopped\n".utf8))
        } catch {
            throw CLIError(errorDescription: "Failed to stream BGRA video: \(error.localizedDescription)")
        }
    }
}