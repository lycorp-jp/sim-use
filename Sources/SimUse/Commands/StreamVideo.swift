// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import SimUseVideo
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `stream-video` verb (#78). Owns the flag
/// surface and resolves the target platform, then delegates to:
///
///   * `IOSSimStreamVideoCommand.execute()` for iOS Simulator UDIDs
///     (native `FBVideoStream` h264 in MPEG-TS and raw `bgra`, plus the
///     deprecated screenshot-capture formats).
///   * `AndroidStreamVideoCommand.stream()` for adb serials (`screenrecord`
///     h264 re-containered into MPEG-TS + screencap JPEG formats).
struct StreamVideo: SimUseExecutableCommand {
    /// Union of both backends' formats. `h264` and the deprecated
    /// `mjpeg` / `raw` / `ffmpeg` are shared; `bgra` is iOS-only (raw
    /// FBVideoStream pixels) and fails on Android with a pointer to the
    /// right alternative.
    enum OutputFormat: String, ExpressibleByArgument, Codable {
        case mjpeg
        case raw
        case ffmpeg
        case bgra
        case h264
    }

    struct ExecutionResult: Codable {
        let framesStreamed: UInt64
        let bytesStreamed: UInt64?
        let durationSeconds: Double
    }

    static let configuration = CommandConfiguration(
        commandName: "stream-video",
        abstract: "Stream live video from the device display to stdout"
    )

    @OptionGroup var device: DeviceOptions

    @Option(help: "Output format: h264 (native H.264 in MPEG-TS on both platforms — fastest, recommended); mjpeg, raw, ffmpeg (screenshot loop; DEPRECATED on iOS, retained on Android for devices where screenrecord is unavailable); bgra (iOS-only raw pixels). Default: mjpeg")
    var format: OutputFormat = .mjpeg

    @Option(help: "Frames per second (1-30). iOS --format h264 streams at this constant rate (default 30); the screenshot formats default to 10; Android's h264 ignores it (native variable frame rate).")
    var fps: Int?

    @Option(help: "JPEG quality (1-100, default: 80)")
    var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0, default: 1.0)")
    var scale: Double = 1.0

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve(allowPhysical: true)
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    var daemonBypass: Bool { true }

    func validate() throws {
        // stdout carries the raw video bytes; the JSON envelope would be
        // appended to the same stream after execute() and corrupt it for
        // any consumer.
        if json.enabled {
            throw ValidationError("--json is not available on stream-video: stdout carries the raw video bytes and the envelope would corrupt the stream. The run summary is printed to stderr instead.")
        }
        try VideoRecordingOptions.validateStreaming(fps: fps, quality: quality, scale: scale)
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        guard result.durationSeconds > 0 else { return .empty }
        if result.framesStreamed > 0 {
            let avgFPS = Double(result.framesStreamed) / result.durationSeconds
            let line = String(
                format: "Streamed %llu frames in %.1f seconds (%.1f FPS average)\n",
                result.framesStreamed,
                result.durationSeconds,
                avgFPS
            )
            return CommandOutput(stderr: line)
        }
        if let bytes = result.bytesStreamed, bytes > 0 {
            let line = String(
                format: "Streamed %llu bytes in %.1f seconds\n",
                bytes,
                result.durationSeconds
            )
            return CommandOutput(stderr: line)
        }
        return .empty
    }

    func execute() async throws -> ExecutionResult {
        switch PlatformRouter.resolve(udid: device.resolved) {
        case .android:
            return try await executeAndroid()
        case .iOSDevice:
            throw TargetCapabilityError.physicalIOS(
                verb: "stream-video",
                reason: "video capture is not wired up for physical devices (CoreDevice screen recording is capability-gated per device).",
                alternative: "Capture stills instead: `sim-use screenshot` works on any screen, system apps included."
            )
        case .iOSSim, .none:
            return try await executeIOSSim()
        }
    }

    /// Map the top-level format onto the iOS backend's enum. Every format
    /// has an iOS mapping; only `bgra` lacks an Android one.
    static func iosFormat(for format: OutputFormat) -> IOSSimStreamVideoCommand.OutputFormat? {
        switch format {
        case .mjpeg: return .mjpeg
        case .raw: return .raw
        case .ffmpeg: return .ffmpeg
        case .bgra: return .bgra
        case .h264: return .h264
        }
    }

    /// Map the top-level format onto the Android backend's enum; nil for
    /// the iOS-only `bgra`.
    static func androidFormat(for format: OutputFormat) -> AndroidStreamVideoCommand.OutputFormat? {
        switch format {
        case .mjpeg: return .mjpeg
        case .raw: return .raw
        case .ffmpeg: return .ffmpeg
        case .h264: return .h264
        case .bgra: return nil
        }
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        let sub = makeIOSSubcommand()
        let result = try await sub.execute()
        return ExecutionResult(
            framesStreamed: result.framesStreamed,
            bytesStreamed: nil,
            durationSeconds: result.durationSeconds,
        )
    }

    /// Construct the backend command and copy every parsed flag across.
    /// A missed field stays in ArgumentParser's wrapper-definition state
    /// and traps on first read (#42) — pinned by
    /// `ForwarderInitializationGuardTests`.
    func makeIOSSubcommand() -> IOSSimStreamVideoCommand {
        var sub = IOSSimStreamVideoCommand()
        // Every top-level format maps to iOS; the fallback only keeps this
        // constructor total.
        sub.format = Self.iosFormat(for: format) ?? .mjpeg
        sub.fps = fps
        sub.quality = quality
        sub.scale = scale
        sub.device = device
        sub.json = json
        return sub
    }

    private func executeAndroid() async throws -> ExecutionResult {
        guard let androidFormat = Self.androidFormat(for: format) else {
            throw CLIError(errorDescription: "--format bgra is iOS-only (raw FBVideoStream pixel output). Use h264 for a native Android stream, or mjpeg/raw/ffmpeg.")
        }
        let result = try await AndroidStreamVideoCommand.stream(
            serial: device.resolved,
            format: androidFormat,
            fps: fps,
            quality: quality,
            scale: scale
        )
        return ExecutionResult(
            framesStreamed: result.framesStreamed,
            bytesStreamed: result.bytesStreamed,
            durationSeconds: result.durationSeconds,
        )
    }
}
