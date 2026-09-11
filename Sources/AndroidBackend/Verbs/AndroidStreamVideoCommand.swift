// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import os
import SimUseCore
import SimUseVideo

/// `sim-use android stream-video` — stream live video to stdout (#78).
///
/// Two engines behind one flag surface:
///
///   * `h264` — `adb exec-out screenrecord --output-format=h264 -`,
///     re-containered into MPEG-TS without re-encoding: variable frame
///     rate, cheap, high quality. screenrecord's
///     per-invocation time limit is papered over by restarting it and
///     continuing the stream (same segment loop as
///     `AndroidRecordVideoCommand`, with the MP4 recorder swapped for the
///     transport-stream writer); each new segment re-emits SPS/PPS, which
///     mainstream decoders (ffplay, ffmpeg) accept mid-stream.
///   * `mjpeg` / `raw` / `ffmpeg` — a `screencap`-per-frame loop
///     (~7–8 FPS ceiling) with byte-identical on-the-wire framing to the
///     iOS `stream-video` formats, so existing consumers work unchanged.
///
/// `bgra` is intentionally absent: it is raw `FBVideoStream` pixel output
/// and has no Android analog.
public struct AndroidStreamVideoCommand: SimUseExecutableCommand {
    public enum OutputFormat: String, ExpressibleByArgument, Codable, Sendable {
        case mjpeg
        case raw
        case ffmpeg
        case h264
    }

    /// Summary of a completed stream run. The video bytes are written to
    /// stdout inline during `execute()` — they are a side channel, not part
    /// of the Result (same posture as `IOSSimStreamVideoCommand`). Every
    /// format counts frames; `h264` also reports bytes, which is all there
    /// is to say about a run that produced no picture at all.
    public struct ExecutionResult: Codable {
        public let framesStreamed: UInt64
        public let bytesStreamed: UInt64
        public let durationSeconds: Double
        public let format: OutputFormat

        public init(framesStreamed: UInt64, bytesStreamed: UInt64, durationSeconds: Double, format: OutputFormat) {
            self.framesStreamed = framesStreamed
            self.bytesStreamed = bytesStreamed
            self.durationSeconds = durationSeconds
            self.format = format
        }
    }

    public static let configuration = CommandConfiguration(
        commandName: "stream-video",
        abstract: "Stream live video from the Android device display to stdout"
    )

    @OptionGroup public var device: AndroidDeviceOptions

    @Option(help: "Output format: h264 (screenrecord in MPEG-TS, no re-encoding — fastest, recommended), mjpeg, raw, ffmpeg (screencap JPEG loop). Default: mjpeg")
    public var format: OutputFormat = .mjpeg

    @Option(help: "Frames per second for the JPEG formats (1-30, default: 10). Ignored by --format h264 (native variable frame rate).")
    public var fps: Int?

    @Option(help: "JPEG quality for the JPEG formats / bitrate factor for h264 (1-100, default: 80)")
    public var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0, default: 1.0)")
    public var scale: Double = 1.0

    @Flag(name: .customLong("json"), help: "Unavailable on stream-video — the video bytes own stdout. The flag exists only so agents get a targeted error instead of 'Unknown option'.")
    public var jsonOutput: Bool = false

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    /// Streams raw bytes to the caller's stdout for the lifetime of the
    /// command — the daemon transport cannot carry that.
    public var daemonBypass: Bool { true }

    public func validate() throws {
        // stdout carries the raw video bytes; the JSON envelope would be
        // appended to the same stream after execute() and corrupt it.
        if jsonOutput {
            throw ValidationError("--json is not available on stream-video: stdout carries the raw video bytes and the envelope would corrupt the stream. The run summary is printed to stderr instead.")
        }
        try VideoRecordingOptions.validateStreaming(fps: fps, quality: quality, scale: scale)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        guard result.durationSeconds > 0 else { return .empty }
        // Frames are the useful unit and what the top-level verb prints.
        // A still screen under a variable-frame-rate source can genuinely
        // produce none, and bytes are the only thing left to report.
        if result.framesStreamed == 0 {
            guard result.bytesStreamed > 0 else { return .empty }
            let line = String(
                format: "Streamed %llu bytes in %.1f seconds\n",
                result.bytesStreamed,
                result.durationSeconds
            )
            return CommandOutput(stderr: line)
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

    public func execute() async throws -> ExecutionResult {
        try await Self.stream(
            serial: device.resolved,
            format: format,
            fps: fps,
            quality: quality,
            scale: scale
        )
    }

    // MARK: - Shared orchestration

    /// Reusable Android streaming entry point: runs until SIGINT/SIGTERM
    /// or the consumer closes stdout, then returns the run summary. The
    /// top-level cross-platform `StreamVideo` forwards here for Android
    /// UDIDs — symmetric to `AndroidRecordVideoCommand.record`.
    public static func stream(
        serial: String,
        format: OutputFormat,
        fps: Int?,
        quality: Int,
        scale: Double
    ) async throws -> ExecutionResult {
        let adb = Adb()
        try AndroidRecordVideoCommand.assertAdbDeviceOnline(adb: adb, serial: serial)

        let cancellationFlag = CancellationFlag()
        let signalObserver = SignalObserver(signals: [SIGINT, SIGTERM]) {
            cancellationFlag.cancel()
        }
        defer { signalObserver.invalidate() }

        switch format {
        case .h264:
            return try await streamH264(
                adb: adb,
                serial: serial,
                fps: fps,
                quality: quality,
                scale: scale,
                cancellationFlag: cancellationFlag
            )
        case .mjpeg, .raw, .ffmpeg:
            return try await streamJPEGFrames(
                adb: adb,
                serial: serial,
                format: format,
                fps: fps ?? 10,
                quality: quality,
                scale: scale,
                cancellationFlag: cancellationFlag
            )
        }
    }

    // MARK: - h264 stream

    /// Native stream: `adb exec-out screenrecord --output-format=h264 -`
    /// re-containered into MPEG-TS on the way to stdout. Mirrors the
    /// segment-restart loop in
    /// `AndroidRecordVideoCommand.recordVideoAndroidStream` — kept separate
    /// because the sink (stdout vs file), the error taxonomy (no screencap
    /// fallback for an explicitly chosen format), and the end-of-stream
    /// semantics (consumer hangup is an orderly stop) all differ.
    ///
    /// screenrecord's own output is bare Annex B, which carries no
    /// timestamps at all. A player fed it assumes a frame rate — ffmpeg
    /// assumes 25 fps — and since the device commonly encodes faster, the
    /// consumer drains slower than sim-use fills and the lag grows without
    /// bound rather than settling. MPEG-TS carries a PTS per picture, so the
    /// player paces off the stream. Nothing is re-encoded; only the
    /// container changes.
    private static func streamH264(
        adb: Adb,
        serial: String,
        fps: Int?,
        quality: Int,
        scale: Double,
        cancellationFlag: CancellationFlag
    ) async throws -> ExecutionResult {
        if fps != nil {
            FileHandle.standardError.write(Data("note: --fps is ignored for --format h264 (screenrecord records at native variable frame rate)\n".utf8))
        }

        let sdk = AndroidRecordVideoCommand.detectSDK(adb: adb, serial: serial)
        let baseSize = AndroidRecordVideoCommand.detectSize(adb: adb, serial: serial)
        let recordingSize = scale < 1.0 ? baseSize.map { AndroidRecordVideoCommand.scaledSize($0, scale: scale) } : nil
        let bitrateSize = recordingSize ?? baseSize
        let bitrate = bitrateSize.map { H264StreamRecorder.estimateBitrate(width: $0.width, height: $0.height, fps: 30, quality: quality) }
        let arguments = AndroidRecordVideoCommand.screenrecordArguments(
            serial: serial,
            sdk: sdk,
            bitrate: bitrate,
            size: recordingSize,
            timeLimitOverride: AndroidRecordVideoCommand.screenrecordTimeLimitOverride()
        )

        FileHandle.standardError.write(Data("Streaming Android device \(serial) (h264 in MPEG-TS)...\n".utf8))
        FileHandle.standardError.write(Data("Note: carries PTS, so players pace correctly. Preview it live:\n".utf8))
        FileHandle.standardError.write(Data("  sim-use android stream-video --format h264 --device \(serial) | ffplay -f mpegts -probesize 32768 -i -\n".utf8))
        FileHandle.standardError.write(Data("Note: capture is variable-frame-rate — a still screen produces no frames, so the picture holds until the device moves again.\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop streaming\n".utf8))

        let sink = StdoutStreamSink(shouldAbort: { Task.isCancelled || cancellationFlag.isCancelled() })
        let tsWriter = MPEGTSStreamWriter { data in
            if !sink.write(data) {
                // Consumer closed its end (ffplay quit, `head` done).
                cancellationFlag.cancel()
            }
        }

        // Announce the stream structure before the first picture: on a
        // variable-frame-rate source a still screen yields no frames at all,
        // and a consumer that attached would otherwise read nothing.
        tsWriter.emitProgramTables()

        let fatalBox = FirstErrorBox()
        let pipeline = H264MuxingPipeline(sink: tsWriter, onFatalError: { error in
            fatalBox.set(error)
            cancellationFlag.cancel()
        })

        let startTime = Date()
        var firstSegment = true

        segmentLoop: while true {
            if Task.isCancelled || cancellationFlag.isCancelled() || sink.isBroken { break }
            if fatalBox.first != nil { break }

            // Each restarted segment re-emits SPS/PPS, so the parser starts
            // clean; the single host clock keeps PTS continuous across the gap.
            pipeline.resetParserForNewSegment()
            let process = AdbStreamingProcess(
                adbPath: adb.binaryPath,
                arguments: arguments,
                onStdout: { data in pipeline.ingest(data) }
            )
            do {
                try process.start()
            } catch {
                if firstSegment {
                    throw CLIError(errorDescription: "screenrecord unavailable (\(error.localizedDescription)). Use --format mjpeg for the screencap-based stream instead.")
                }
                throw error
            }
            firstSegment = false

            let segmentStartBytes = process.stdoutByteCount
            var lastKeepAlive = Date()
            while process.isRunning {
                if Task.isCancelled || cancellationFlag.isCancelled() || sink.isBroken { break }
                if fatalBox.first != nil { break }
                try? await cancellableSleep(seconds: 0.05, flag: cancellationFlag)

                // Re-announce the program tables periodically. This is
                // ordinary practice for a transport stream — it is how a
                // consumer attaching mid-stream learns its structure — and
                // it doubles as the keep-alive that surfaces a hung-up
                // consumer. Without it a still screen produces no frames,
                // nothing is ever written, and a closed pipe would go
                // unnoticed until the device happened to move again.
                if Date().timeIntervalSince(lastKeepAlive) >= 0.1 {
                    tsWriter.emitProgramTables()
                    lastKeepAlive = Date()
                }
            }

            let stopping = Task.isCancelled || cancellationFlag.isCancelled() || sink.isBroken || fatalBox.first != nil
            if stopping {
                process.interrupt()
                process.waitForExit(timeout: 2)
                break
            }

            // The process exited on its own — a clean exit 0 is the time
            // limit (restart to continue); anything else is a dead device,
            // adb, or encoder, which must NOT be blind-restarted into a
            // crash loop just because the segment produced some bytes.
            let exitCode = process.waitForExit(timeout: 2)
            let bytesThisSegment = process.stdoutByteCount - segmentStartBytes
            let stderrTail = process.collectedStderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if bytesThisSegment == 0 {
                if !pipeline.firstFrameReceived {
                    let exitDescription = exitCode.map(String.init) ?? "timeout"
                    throw CLIError(errorDescription: "screenrecord produced no output (exit \(exitDescription)): \(stderrTail). Use --format mjpeg for the screencap-based stream instead.")
                }
                throw CLIError(errorDescription: "Android device stopped producing frames during streaming (\(stderrTail))")
            }
            guard exitCode == 0 else {
                let exitDescription = exitCode.map(String.init) ?? "timeout"
                throw CLIError(errorDescription: "screenrecord exited unexpectedly (exit \(exitDescription)) mid-stream: \(stderrTail)")
            }
            FileHandle.standardError.write(Data("screenrecord segment ended (time limit); restarting stream (~100-300ms gap; the new segment re-emits SPS/PPS)\n".utf8))
        }

        pipeline.finishIngest()
        if let fatal = fatalBox.first { throw fatal }

        let elapsed = Date().timeIntervalSince(startTime)
        return ExecutionResult(
            framesStreamed: UInt64(pipeline.framesWritten),
            bytesStreamed: sink.bytesWritten,
            durationSeconds: elapsed,
            format: .h264
        )
    }

    // MARK: - screencap JPEG loop

    /// JPEG-frame stream over a `screencap`-per-frame loop, with the same
    /// on-the-wire framing as `IOSSimStreamVideoCommand`:
    /// `mjpeg` = multipart/x-mixed-replace with `--mjpegstream` boundaries,
    /// `raw` = 4-byte big-endian length prefix per frame,
    /// `ffmpeg` = bare concatenated frames.
    private static func streamJPEGFrames(
        adb: Adb,
        serial: String,
        format: OutputFormat,
        fps: Int,
        quality: Int,
        scale: Double,
        cancellationFlag: CancellationFlag
    ) async throws -> ExecutionResult {
        FileHandle.standardError.write(Data("Starting screencap-based video stream from Android device \(serial)...\n".utf8))
        FileHandle.standardError.write(Data("Format: \(format.rawValue), FPS: \(fps), Quality: \(quality), Scale: \(scale)\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop streaming\n".utf8))

        let frameInterval = 1.0 / Double(fps)
        let mjpegBoundary = "--mjpegstream"
        let sink = StdoutStreamSink(shouldAbort: { Task.isCancelled || cancellationFlag.isCancelled() })

        if format == .mjpeg {
            let header = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=\(mjpegBoundary)\r\n\r\n"
            sink.write(Data(header.utf8))
        }

        var frameCount: UInt64 = 0
        let startTime = Date()
        let adbPath = adb.binaryPath

        while true {
            if Task.isCancelled || cancellationFlag.isCancelled() || sink.isBroken {
                break
            }

            let frameStartTime = Date()

            do {
                let frameData = try AndroidRecordVideoCommand.captureAndroidScreencap(adbPath: adbPath, serial: serial)
                let processedData = try await VideoFrameUtilities.processJPEGData(frameData, scale: scale, quality: quality)

                switch format {
                case .mjpeg:
                    let frameHeader = "\(mjpegBoundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(processedData.count)\r\n\r\n"
                    sink.write(Data(frameHeader.utf8))
                    sink.write(processedData)
                    sink.write(Data("\r\n".utf8))
                case .raw:
                    var length = UInt32(processedData.count).bigEndian
                    sink.write(Data(bytes: &length, count: 4))
                    sink.write(processedData)
                case .ffmpeg:
                    sink.write(processedData)
                case .h264:
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

        if format == .mjpeg && !sink.isBroken {
            sink.write(Data("\(mjpegBoundary)--\r\n".utf8))
        }

        let elapsed = Date().timeIntervalSince(startTime)
        return ExecutionResult(
            framesStreamed: frameCount,
            bytesStreamed: sink.bytesWritten,
            durationSeconds: elapsed,
            format: format
        )
    }
}
