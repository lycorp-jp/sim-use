// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `swipe` verb. Owns the verb-specific flag
/// surface, resolves the target platform via `PlatformRouter`, then
/// delegates to the per-backend command struct (`IOSSimSwipeCommand`
/// for iOS UDIDs, `AndroidSwipeCommand.performSwipe` for adb
/// serials). Shared flag groups (`DeviceOptions`, `JSONOutputOptions`)
/// live in `SimUseCore/Options/` so the declaration is identical to
/// the one consumed by `sim-use ios swipe`.
struct Swipe: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimSwipeCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        abstract: "Perform a swipe gesture from one point to another on the screen."
    )

    @Option(name: .customLong("start-x"), help: "The X coordinate of the starting point.")
    var startX: Double

    @Option(name: .customLong("start-y"), help: "The Y coordinate of the starting point.")
    var startY: Double

    @Option(name: .customLong("end-x"), help: "The X coordinate of the ending point.")
    var endX: Double

    @Option(name: .customLong("end-y"), help: "The Y coordinate of the ending point.")
    var endY: Double

    @Option(name: .customLong("duration"), help: "Duration of the swipe in seconds.")
    var duration: Double?

    @Option(name: .customLong("delta"), help: "Distance between touch points in pixels.")
    var delta: Double?

    @Option(name: .customLong("pre-delay"), help: "Delay before starting the swipe in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after completing the swipe in seconds.")
    var postDelay: Double?

    @OptionGroup var device: DeviceOptions

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    /// Mirror `Tap` / `Button`'s "✓ … completed successfully" line.
    /// Without this the cross-platform `sim-use swipe` is silent on
    /// success in non-JSON mode, which is inconsistent with the other
    /// verbs and surprised users during release testing. Coordinates
    /// are rendered as integers for compactness; the iOS HID layer
    /// happens to consume them as Doubles but the user-facing
    /// numbers stay readable.
    func format(_ result: ExecutionResult) -> CommandOutput {
        let sx = Int(startX.rounded())
        let sy = Int(startY.rounded())
        let ex = Int(endX.rounded())
        let ey = Int(endY.rounded())
        return .line("✓ Swipe (\(sx),\(sy)) → (\(ex),\(ey)) completed successfully")
    }

    func validate() throws {
        try IOSSimSwipeCommand.validateOptions(
            startX: startX, startY: startY,
            endX: endX, endY: endY,
            duration: duration,
            delta: delta,
            preDelay: preDelay,
            postDelay: postDelay
        )
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
        var sub = IOSSimSwipeCommand()
        sub.startX = startX
        sub.startY = startY
        sub.endX = endX
        sub.endY = endY
        sub.duration = duration
        sub.delta = delta
        sub.preDelay = preDelay
        sub.postDelay = postDelay
        sub.device = device
        sub.json = json
        return try await sub.execute()
    }

    /// Android dispatch. `duration` (iOS seconds) is re-mapped to
    /// milliseconds (Android bridge unit). `--delta` is iOS-HID
    /// granularity and has no Android equivalent (dispatchGesture
    /// interpolates internally), so it's silently ignored here.
    /// `pre-delay` / `post-delay` honored via `Task.sleep` around
    /// the bridge call — mirrors `Gesture.swift`'s `executeAndroid`.
    private func executeAndroid() async throws -> ExecutionResult {
        let durationMs = max(1, Int((duration ?? 0.3) * 1000))
        if let preDelay, preDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(preDelay * 1_000_000_000))
        }
        try AndroidSwipeCommand.performSwipe(
            udid: device.resolved,
            startX: Int(startX),
            startY: Int(startY),
            endX: Int(endX),
            endY: Int(endY),
            durationMs: durationMs
        )
        if let postDelay, postDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(postDelay * 1_000_000_000))
        }
        return ExecutionResult()
    }
}