// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `describe-ui` verb. Owns the flag surface
/// and resolves the target platform, then delegates to the per-backend
/// command (`IOSSimDescribeUICommand` for iOS Simulator UDIDs,
/// `AndroidDescribeUICommand.performDescribeUI` for adb serials).
///
/// `--include-offscreen` is Android-only — silently ignored on iOS
/// (the iOS pipeline has no equivalent visibility flag).
struct DescribeUI: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimDescribeUICommand.ExecutionResult

    static let configuration = CommandConfiguration(
        abstract: "Describes the UI hierarchy of a booted simulator using accessibility information.",
        aliases: ["ui"]
    )

    @OptionGroup var device: DeviceOptions

    @Option(
        name: .customLong("point"),
        help: ArgumentHelp(
            "Describe only the accessibility element at screen coordinates x,y.",
            valueName: "x,y"
        )
    )
    var point: CoordinatePair?

    @Option(
        name: .customLong("max-probes"),
        help: ArgumentHelp(
            "Probe budget for collapsed-children / blind-zone recovery (default 300). Higher values expand coverage in large WebView-like regions at the cost of latency.",
            valueName: "n"
        )
    )
    var maxProbes: Int = 300

    @Option(
        name: .customLong("min-cell-size"),
        help: ArgumentHelp(
            "Minimum quadtree cell size in points (default 14). Lower values reach finer elements (thin nav bars, tiny icons) at the cost of more probes.",
            valueName: "pt"
        )
    )
    var minCellSize: Double = 14

    @Option(
        name: .customLong("seed-cell-width"),
        help: ArgumentHelp(
            "Initial X-stride of the quadtree seed grid in points (default 160). Advanced tuning — smaller values give finer X-resolution but more seed probes; larger values are faster on wide-element screens.",
            valueName: "pt"
        )
    )
    var seedCellWidth: Double = 160

    @Option(
        name: .customLong("seed-cell-height"),
        help: ArgumentHelp(
            "Initial Y-stride of the quadtree seed grid in points (default 80). Advanced tuning — lower it if the screen has many thin horizontal rows you want to reach in the first probe pass.",
            valueName: "pt"
        )
    )
    var seedCellHeight: Double = 80

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    @Flag(
        name: .customLong("include-offscreen"),
        help: "Android-only. Include nodes whose `isVisibleToUser` is false (recycled list cells, off-screen ViewPager neighbours, fragments mid-detach). Default is to filter them out — they pad the outline with rows the user can't actually see. Ignored on iOS (the iOS pipeline has no equivalent visibility flag)."
    )
    var includeOffscreen: Bool = false

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    func validate() throws {
        try IOSSimDescribeUICommand.validatePoint(point)
        try IOSSimDescribeUICommand.validateOptions(
            maxProbes: maxProbes,
            minCellSize: minCellSize,
            seedCellWidth: seedCellWidth,
            seedCellHeight: seedCellHeight
        )
    }

    func execute() async throws -> ExecutionResult {
        switch PlatformRouter.resolve(udid: device.resolved) {
        case .android:
            return try executeAndroid()
        case .iOSSim, .none:
            return try await executeIOSSim()
        }
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        .raw(result.outline)
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        var sub = IOSSimDescribeUICommand()
        sub.point = point
        sub.maxProbes = maxProbes
        sub.minCellSize = minCellSize
        sub.seedCellWidth = seedCellWidth
        sub.seedCellHeight = seedCellHeight
        sub.device = device
        sub.json = json
        return try await sub.execute()
    }

    /// Android dispatch: routes through `AndroidDescribeUICommand.performDescribeUI`
    /// (shared with `sim-use android describe-ui`) and reshapes the
    /// cross-platform `DescribeUIResult` into this command's local
    /// `ExecutionResult` shape so callers — including the daemon
    /// wire — see a single envelope regardless of platform.
    private func executeAndroid() throws -> ExecutionResult {
        let result = try AndroidDescribeUICommand.performDescribeUI(
            udid: device.resolved,
            includeOffscreen: includeOffscreen,
            includeRaw: jsonOutput
        )
        return ExecutionResult(
            platform: result.platform.rawValue,
            raw: result.raw,
            outline: result.outline,
            entries: result.entries,
            lists: result.lists,
            screen: result.screen,
            appLabel: result.appLabel,
            appPackage: result.appPackage,
            crashDialog: result.crashDialog
        )
    }
}