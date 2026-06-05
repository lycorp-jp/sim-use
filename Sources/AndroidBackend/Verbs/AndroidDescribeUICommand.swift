// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android describe-ui` — render the Android device's current
/// UI through the bridge into the cross-platform outline shape.
public struct AndroidDescribeUICommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "describe-ui",
        abstract: "Describe the Android device's current UI via the bridge."
    )

    @OptionGroup public var device: AndroidDeviceOptions

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: DescribeUIResult}` envelope (compact, sortedKeys). Includes the raw bridge tree under `data.raw`.")
    public var jsonOutput: Bool = false

    @Flag(name: .customLong("include-offscreen"), help: "Include elements whose bounds fall outside the screen (default: filter them out).")
    public var includeOffscreen: Bool = false

    public init() {}

    public typealias ExecutionResult = DescribeUIResult

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        try Self.performDescribeUI(
            udid: device.resolved,
            includeOffscreen: includeOffscreen,
            // `raw` adds ~50–200 KB to the encoded envelope; only pay
            // the cost when the caller asked for JSON.
            includeRaw: jsonOutput
        )
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .raw(result.outline)
    }

    /// Reusable Android describe-ui entry point. Top-level
    /// cross-platform `DescribeUI` forwards here for Android UDIDs so
    /// both `sim-use android describe-ui` and `sim-use describe-ui`
    /// share one body. Symmetric to `AndroidTapCommand.performTap`.
    public static func performDescribeUI(
        udid: String,
        includeOffscreen: Bool,
        includeRaw: Bool,
        controller: AndroidDeviceController = AndroidDeviceController()
    ) throws -> DescribeUIResult {
        let opts = AndroidOutlineRenderer.RendererOptions(filterOffscreen: !includeOffscreen)
        return try controller.describeUI(serial: udid, options: opts, includeRaw: includeRaw)
    }
}