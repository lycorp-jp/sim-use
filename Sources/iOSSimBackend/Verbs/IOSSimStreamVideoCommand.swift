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
        case h264

        /// Formats served by a native `FBVideoStream` copied straight to
        /// stdout, with no host-side codec pass. The screenshot-backed
        /// formats re-encode every frame instead.
        var isNativeStream: Bool {
            switch self {
            case .bgra, .h264: true
            case .mjpeg, .raw, .ffmpeg: false
            }
        }

        /// The screenshot-per-frame formats, superseded on this platform by
        /// `h264`. Measured on a booted iPhone 17 Pro over 6 s: `h264`
        /// delivers 144 frames in 1.33 MB where `mjpeg` manages 24 in
        /// 11.2 MB and the PNG-carrying formats 26 in 92.8 MB. `h264` works
        /// on every booted simulator, so no state remains in which these are
        /// the better choice.
        ///
        /// Android keeps its equivalents: `adb screenrecord` is unavailable
        /// on some devices, and there the screencap loop is the only way to
        /// stream at all.
        var isDeprecated: Bool {
            switch self {
            case .mjpeg, .raw, .ffmpeg: true
            case .h264, .bgra: false
            }
        }

        /// One-line reason shown once when a deprecated format is used.
        var deprecationNotice: String {
            "warning: --format \(rawValue) is deprecated on iOS and will be removed. Use --format h264 — a native H.264 stream in MPEG-TS, roughly 6x the frame rate at an eighth of the bytes, with no host-side codec pass. Preview it with `| ffplay -f mpegts -analyzeduration 0 -probesize 32768 -i -`.\n"
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
        abstract: "Stream simulator video to stdout"
    )

    @OptionGroup public var device: DeviceOptions

    @Option(help: "Output format: h264 (native H.264 in MPEG-TS — fastest, recommended), mjpeg, raw, ffmpeg (DEPRECATED screenshot loop, ~6x slower and ~8x larger; will be removed), bgra (experimental raw pixels). Default: mjpeg. No frame count is reported for bgra.")
    public var format: OutputFormat = .mjpeg

    @Option(help: "Frames per second (1-30, default: 10)")
    public var fps: Int = 10

    @Option(help: "Encode quality (1-100, default: 80): H.264 rate control for h264, JPEG quality for the screenshot formats.")
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
        if format.isDeprecated {
            FileHandle.standardError.write(Data(format.deprecationNotice.utf8))
        }

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

        if format.isNativeStream {
            try await streamNative(from: targetSimulator, format: format, cancellationFlag: cancellationFlag)
            // The native paths copy encoded bytes through FBVideoStream and
            // do not track frame counts; return a zero-summary so
            // `format(_:)` emits nothing.
            return ExecutionResult(framesStreamed: 0, durationSeconds: 0, format: format)
        }
        return try await streamCompressedFrames(from: targetSimulator, format: format, cancellationFlag: cancellationFlag)
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
                case .bgra, .h264:
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

    // MARK: - Native FBVideoStream passthrough

    /// Copies a native `FBVideoStream` straight to stdout, with no
    /// host-side codec pass.
    ///
    /// `h264` runs the very configuration `record-video` muxes into an MP4:
    /// the two verbs drive the same framebuffer encode and differ only in
    /// their sink. `bgra` carries raw pixels for callers that want them
    /// unencoded.
    private func streamNative(
        from simulator: FBSimulator,
        format: OutputFormat,
        cancellationFlag: CancellationFlag
    ) async throws {
        let configuration: FBVideoStreamConfiguration
        switch format {
        case .h264:
            configuration = .h264Capture(fps: fps, quality: quality, scale: scale, transport: .mpegts)
            FileHandle.standardError.write(Data("Starting h264 video stream from simulator \(simulator.udid)...\n".utf8))
            FileHandle.standardError.write(Data("Format: h264, FPS: \(fps), Quality: \(quality), Scale: \(scale)\n".utf8))
            FileHandle.standardError.write(Data("Note: H.264 in MPEG-TS (carries PTS, so players pace correctly). Preview it live:\n".utf8))
            FileHandle.standardError.write(Data("  sim-use ios stream-video --format h264 --udid <UDID> | ffplay -f mpegts -analyzeduration 0 -probesize 32768 -i -\n".utf8))
        default:
            configuration = FBVideoStreamConfiguration(
                format: .bgra,
                framesPerSecond: nil,
                rateControl: .quality(Double(quality) / 100.0),
                scaleFactor: scale,
                keyFrameRate: nil
            )
            FileHandle.standardError.write(Data("Starting BGRA video stream from simulator \(simulator.udid)...\n".utf8))
            FileHandle.standardError.write(Data("Format: bgra, Quality: \(quality), Scale: \(scale)\n".utf8))
            FileHandle.standardError.write(Data("Note: This is raw pixel data. Use ffmpeg to convert:\n".utf8))
            FileHandle.standardError.write(Data("  sim-use ios stream-video --format bgra --udid <UDID> | ffmpeg -f rawvideo -pixel_format bgra -video_size WIDTHxHEIGHT -i - output.mp4\n".utf8))
        }
        FileHandle.standardError.write(Data("Press Ctrl+C to stop streaming\n".utf8))

        let label = format.rawValue
        do {
            let stdoutConsumer = FBFileWriter.syncWriter(withFileDescriptor: STDOUT_FILENO, closeOnEndOfFile: false)
            // The stream comes back already running — attach failures throw
            // here instead of surfacing asynchronously.
            let videoStream = try await simulator.createStream(configuration: configuration, to: stdoutConsumer)
            FileHandle.standardError.write(Data("\(label) stream is now running...\n".utf8))

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

            FileHandle.standardError.write(Data("\nStopping \(label) stream...\n".utf8))
            try await videoStream.stopStreaming()
            await completionTask.value
            FileHandle.standardError.write(Data("\(label) stream stopped\n".utf8))
        } catch {
            throw CLIError(errorDescription: "Failed to stream \(label) video: \(error.localizedDescription)")
        }
    }
}
