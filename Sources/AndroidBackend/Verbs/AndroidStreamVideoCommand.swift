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
///   * `h264` — native `adb exec-out screenrecord --output-format=h264 -`
///     passthrough: variable frame rate, cheap, high quality. screenrecord's
///     per-invocation time limit is papered over by restarting it and
///     continuing the byte stream (same segment loop as
///     `AndroidRecordVideoCommand`, minus the muxer); each new segment
///     re-emits SPS/PPS, which mainstream decoders (ffplay, ffmpeg) accept
///     mid-stream.
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

        /// The container this format's consumers can decode, or nil for
        /// `h264`, which is a byte passthrough. Matches the iOS surface —
        /// `stream-video` promises byte-identical framing across platforms.
        func frameContainer(quality: Int) -> FrameContainer? {
            switch self {
            case .mjpeg: .jpeg(quality: quality)
            case .raw, .ffmpeg: .png
            case .h264: nil
            }
        }
    }

    /// Summary of a completed stream run. The video bytes are written to
    /// stdout inline during `execute()` — they are a side channel, not part
    /// of the Result (same posture as `IOSSimStreamVideoCommand`). The JPEG
    /// formats count frames; `h264` is a byte-passthrough with no frame
    /// notion, so it reports bytes instead.
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

    @Option(help: "Output format: h264 (native screenrecord passthrough), mjpeg, raw, ffmpeg (screencap JPEG loop). Default: mjpeg")
    public var format: OutputFormat = .mjpeg

    @Option(help: "Frames per second for the JPEG formats (1-30, default: 10). Ignored by --format h264 (native variable frame rate).")
    public var fps: Int?

    @Option(help: "JPEG quality for mjpeg / bitrate factor for h264 (1-100, default: 80). Ignored by raw/ffmpeg, which carry lossless PNG frames.")
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
        if result.format == .h264 {
            guard result.bytesStreamed > 0 else { return .empty }
            let line = String(
                format: "Streamed %llu bytes in %.1f seconds\n",
                result.bytesStreamed,
                result.durationSeconds
            )
            return CommandOutput(stderr: line)
        }
        guard result.framesStreamed > 0 else { return .empty }
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
            guard let container = format.frameContainer(quality: quality) else {
                throw CLIError(errorDescription: "Format \(format.rawValue) does not carry encoded frames")
            }
            return try await streamFrames(
                adb: adb,
                serial: serial,
                format: format,
                container: container,
                fps: fps ?? 10,
                scale: scale,
                cancellationFlag: cancellationFlag
            )
        }
    }

    // MARK: - h264 passthrough

    /// Native stream: `adb exec-out screenrecord --output-format=h264 -`
    /// copied byte-for-byte to stdout. Mirrors the segment-restart loop in
    /// `AndroidRecordVideoCommand.recordVideoAndroidStream` — kept separate
    /// because the sink (stdout vs muxer), the error taxonomy (no screencap
    /// fallback for an explicitly chosen format), and the end-of-stream
    /// semantics (consumer hangup is an orderly stop) all differ.
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

        FileHandle.standardError.write(Data("Streaming Android device \(serial) (h264 Annex B passthrough)...\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop streaming\n".utf8))

        let sink = StdoutStreamSink()
        let startTime = Date()
        var firstSegment = true

        segmentLoop: while true {
            if Task.isCancelled || cancellationFlag.isCancelled() || sink.isBroken { break }

            let process = AdbStreamingProcess(
                adbPath: adb.binaryPath,
                arguments: arguments,
                onStdout: { data in
                    if !sink.write(data) {
                        // Consumer closed its end (ffplay quit, `head` done)
                        // — stop producing rather than erroring out.
                        cancellationFlag.cancel()
                    }
                }
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
            while process.isRunning {
                if Task.isCancelled || cancellationFlag.isCancelled() || sink.isBroken { break }
                try? await cancellableSleep(seconds: 0.05, flag: cancellationFlag)
            }

            let stopping = Task.isCancelled || cancellationFlag.isCancelled() || sink.isBroken
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
                if sink.bytesWritten == 0 {
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

        let elapsed = Date().timeIntervalSince(startTime)
        return ExecutionResult(
            framesStreamed: 0,
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
    private static func streamFrames(
        adb: Adb,
        serial: String,
        format: OutputFormat,
        container: FrameContainer,
        fps: Int,
        scale: Double,
        cancellationFlag: CancellationFlag
    ) async throws -> ExecutionResult {
        FileHandle.standardError.write(Data("Starting screencap-based video stream from Android device \(serial)...\n".utf8))
        FileHandle.standardError.write(Data("Format: \(format.rawValue), FPS: \(fps), Frames: \(container), Scale: \(scale)\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop streaming\n".utf8))

        let frameInterval = 1.0 / Double(fps)
        let mjpegBoundary = "--mjpegstream"
        let sink = StdoutStreamSink()

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
                let processedData = try VideoFrameUtilities.transcodeFrame(frameData, to: container, scale: scale)

                switch format {
                case .mjpeg:
                    let frameHeader = "\(mjpegBoundary)\r\nContent-Type: \(container.mimeType)\r\nContent-Length: \(processedData.count)\r\n\r\n"
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

/// POSIX-write stdout sink for streaming bytes.
///
/// `FileHandle.write` raises an uncatchable ObjC exception when the
/// consumer closes its end of the pipe (ffplay quit, `head -c` done) —
/// killing the stream with a crash instead of a summary. This sink
/// ignores SIGPIPE and reports the broken pipe through `isBroken`, so
/// the frame/segment loops can treat consumer hangup as an orderly
/// end-of-stream. Thread-safe: the h264 path writes from the adb reader
/// callback while the command loop polls `isBroken`.
final class StdoutStreamSink: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (bytes: UInt64(0), broken: false))

    init() {
        signal(SIGPIPE, SIG_IGN)
    }

    var bytesWritten: UInt64 { state.withLock { $0.bytes } }
    var isBroken: Bool { state.withLock { $0.broken } }

    /// Write all of `data` to stdout. Returns false once the pipe is
    /// broken; subsequent calls are no-ops.
    @discardableResult
    func write(_ data: Data) -> Bool {
        guard !isBroken else { return false }
        let ok = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), buffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR {
                    continue
                }
                return false
            }
            return true
        }
        state.withLock { state in
            if ok {
                state.bytes += UInt64(data.count)
            } else {
                state.broken = true
            }
        }
        return ok
    }
}
