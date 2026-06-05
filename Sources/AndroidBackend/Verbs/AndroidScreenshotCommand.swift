// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android screenshot` — capture a PNG and write it to a file
/// (default) or stream raw bytes to stdout.
public struct AndroidScreenshotCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a PNG screenshot from the Android device."
    )

    @OptionGroup public var device: AndroidDeviceOptions

    @Option(name: .customLong("output"), help: "Output path. `-` writes raw PNG bytes to stdout (incompatible with --json). Default: ./screenshot.png")
    public var output: String = "screenshot.png"

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {path}}` envelope on success. Mirrors the iOS-side `sim-use ios screenshot --json` shape. Incompatible with `--output -` (the PNG bytes would collide with the envelope on stdout).")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let path: String
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    /// File-system output: the daemon process's cwd differs from the
    /// CLI's, so `--output ./shot.png` would land in the wrong place
    /// if routed through the daemon. Mirror the iOS `Screenshot`
    /// posture and bypass the daemon — the call is already fast over
    /// the bridge's HTTP path.
    public var daemonBypass: Bool { true }

    public func validate() throws {
        if jsonOutput && output == "-" {
            throw ValidationError("--json cannot be combined with `--output -` (stdout would carry both the PNG bytes and the JSON envelope). Pass a real file path or drop --json.")
        }
    }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let pngData = try Self.performScreenshot(udid: device.resolved)
        if output == "-" {
            // text-mode-only path (validate() rejects --json + `-`).
            FileHandle.standardOutput.write(pngData)
            return ExecutionResult(path: "-")
        }
        let url = URL(fileURLWithPath: output)
        try pngData.write(to: url)
        return ExecutionResult(path: url.path)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        guard result.path != "-" else { return .empty }
        // The historical text-mode diagnostic carried the byte count,
        // but plumbing it through `ExecutionResult` would either
        // expand the JSON envelope past `IOSSimScreenshotCommand`'s
        // `{path}` shape (breaking cross-surface parity) or require
        // re-reading the file. Drop it — the path is what matters
        // and the file's existence is already implied by exit code 0.
        return CommandOutput(stderr: "wrote screenshot to \(result.path)\n")
    }

    /// Reusable Android screenshot capture entry point. Top-level
    /// cross-platform `Screenshot` forwards here for Android UDIDs so
    /// both `sim-use android screenshot` and `sim-use screenshot` go
    /// through one body. Symmetric to `AndroidTapCommand.performTap`.
    ///
    /// Returns the raw PNG bytes; the caller is responsible for the
    /// `--output` path-resolution semantics (file / directory / `-`
    /// stdout). Translates the bridge's terse `screenshot_failed`
    /// envelope into the actionable message produced by `friendlier`.
    public static func performScreenshot(
        udid: String,
        controller: AndroidDeviceController = AndroidDeviceController()
    ) throws -> Data {
        let client = controller.bridge(serial: udid)
        do {
            return try client.screenshot()
        } catch {
            throw friendlier(error)
        }
    }

    /// Translate the bridge's terse `screenshot_failed` envelope into
    /// something actionable. The bridge falls into that single error
    /// code for several distinct causes — `AccessibilityService
    /// .takeScreenshot`'s ~500ms minimum interval (the most common
    /// hit during fast loops), API <30 devices, or a general framework
    /// failure. Surface all three so the agent doesn't have to dig
    /// through the bridge code to decode `screenshot_failed`.
    public static func friendlier(_ error: Error) -> Error {
        guard case BridgeError.applicationError(_, "screenshot_failed", _) = error else {
            return error
        }
        return BridgeError.applicationError(
            status: "error",
            code: "screenshot_failed",
            message: "Bridge screenshot failed. Common causes: AccessibilityService.takeScreenshot rate limit (~500ms minimum interval between calls), API <30 device, or generic framework failure. If you need fast capture loops, use `sim-use record-video` (adb exec-out screencap, no rate limit)."
        )
    }
}