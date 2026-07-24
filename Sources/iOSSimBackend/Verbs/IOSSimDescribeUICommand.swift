// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// iOS Simulator backend for the `describe-ui` verb. Mirrors the
/// flag surface of top-level `DescribeUI` and is also reachable
/// directly as `sim-use ios describe-ui`. The top-level command
/// resolves the target platform via `PlatformRouter` and forwards
/// iOS UDIDs through here.
public struct IOSSimDescribeUICommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "describe-ui",
        abstract: "Describes the UI hierarchy of a booted simulator using accessibility information.",
        aliases: ["ui"]
    )

    @OptionGroup public var device: DeviceOptions

    @Option(
        name: .customLong("point"),
        help: ArgumentHelp(
            "Describe only the accessibility element at screen coordinates x,y.",
            valueName: "x,y"
        )
    )
    public var point: CoordinatePair?

    @Option(
        name: .customLong("max-probes"),
        help: ArgumentHelp(
            "Probe budget for collapsed-children / blind-zone recovery (default 300). Higher values expand coverage in large WebView-like regions at the cost of latency.",
            valueName: "n"
        )
    )
    public var maxProbes: Int = 300

    @Option(
        name: .customLong("min-cell-size"),
        help: ArgumentHelp(
            "Minimum quadtree cell size in points (default 14). Lower values reach finer elements (thin nav bars, tiny icons) at the cost of more probes.",
            valueName: "pt"
        )
    )
    public var minCellSize: Double = 14

    @Option(
        name: .customLong("seed-cell-width"),
        help: ArgumentHelp(
            "Initial X-stride of the quadtree seed grid in points (default 160). Advanced tuning — smaller values give finer X-resolution but more seed probes; larger values are faster on wide-element screens.",
            valueName: "pt"
        )
    )
    public var seedCellWidth: Double = 160

    @Option(
        name: .customLong("seed-cell-height"),
        help: ArgumentHelp(
            "Initial Y-stride of the quadtree seed grid in points (default 80). Advanced tuning — lower it if the screen has many thin horizontal rows you want to reach in the first probe pass.",
            valueName: "pt"
        )
    )
    public var seedCellHeight: Double = 80

    @OptionGroup public var json: JSONOutputOptions

    @Flag(
        name: .customLong("no-raw"),
        help: "With --json, omit the raw accessibility tree (`data.raw`) from the envelope. `outline` / `entries` / `lists` are unaffected; on complex screens this cuts the payload by roughly 3-10x."
    )
    public var noRaw: Bool = false

    public var jsonOutput: Bool { json.enabled }

    /// Result shape is structured under `raw` rather than being the bare
    /// tree so the envelope can grow over time without breaking
    /// consumers. `outline` carries the text rendered to stdout in
    /// default mode; `entries` is the structured alias → frame/role/
    /// label/region map; `lists` summarises every detected list cluster
    /// in dominance order so agents that prefer to reason explicitly
    /// about lists can skip the entries walk. See
    /// `DESCRIBE_UI_OUTLINE.md` §4.
    public struct ExecutionResult: Codable, CommandAdvisoryProviding {
        public let platform: String
        /// Raw a11y tree passthrough. `nil` when the client didn't
        /// request `--json`, or opted out with `--no-raw` — the
        /// ~200 KB tree adds 80 ms of round-trip cost otherwise.
        public let raw: JSONValue?
        public let outline: String
        public let entries: [Outline.Entry]
        public let lists: [Outline.ListSummary]
        public let screen: Outline.Frame
        public let appLabel: String
        /// CFBundleIdentifier of the foreground app. iOS V1 leaves this
        /// empty when the AX tree doesn't expose it; resolution via
        /// simctl is a separate follow-up.
        public let appPackage: String
        /// Android-only crash-dialog signal carried through the top-level
        /// `describe-ui` envelope (which shares this iOS-shaped struct).
        /// Always `nil` on iOS — iOS apps disappear on crash rather than
        /// raising a system dialog. Codable omits the key when nil.
        public let crashDialog: CrashDialogSignal?
        /// Calibrated interface orientation of this snapshot (issue #34):
        /// a `DisplayOrientation` raw value on iOS, `nil` on Android
        /// (whose AX space already rotates with the screen) and on
        /// legacy daemons. Codable omits the key when nil.
        public let orientation: String?
        /// Degraded-calibration warning (guessed orientation). Excluded
        /// from the encoded `data` payload via `CodingKeys` — the
        /// envelope hoists it to the top-level `advisory` key. See
        /// `CommandAdvisoryProviding` for the contract.
        public var commandAdvisory: CommandAdvisory? = nil

        public init(
            platform: String,
            raw: JSONValue?,
            outline: String,
            entries: [Outline.Entry],
            lists: [Outline.ListSummary],
            screen: Outline.Frame,
            appLabel: String,
            appPackage: String,
            crashDialog: CrashDialogSignal? = nil,
            orientation: String? = nil,
            commandAdvisory: CommandAdvisory? = nil
        ) {
            self.platform = platform
            self.raw = raw
            self.outline = outline
            self.entries = entries
            self.lists = lists
            self.screen = screen
            self.appLabel = appLabel
            self.appPackage = appPackage
            self.crashDialog = crashDialog
            self.orientation = orientation
            self.commandAdvisory = commandAdvisory
        }

        private enum CodingKeys: String, CodingKey {
            case platform
            case raw
            case outline
            case entries
            case lists
            case screen
            case appLabel
            case appPackage
            case crashDialog
            case orientation
        }
    }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func validate() throws {
        try Self.validatePoint(point)
        try Self.validateOptions(
            maxProbes: maxProbes,
            minCellSize: minCellSize,
            seedCellWidth: seedCellWidth,
            seedCellHeight: seedCellHeight
        )
    }

    /// Shared scalar-option validation. The top-level cross-platform
    /// forwarder delegates here so the rules stay in one place.
    public static func validateOptions(
        maxProbes: Int,
        minCellSize: Double,
        seedCellWidth: Double,
        seedCellHeight: Double
    ) throws {
        if maxProbes < 0 {
            throw ValidationError("--max-probes must be non-negative.")
        }
        if minCellSize <= 0 {
            throw ValidationError("--min-cell-size must be positive.")
        }
        if seedCellWidth <= 0 {
            throw ValidationError("--seed-cell-width must be positive.")
        }
        if seedCellHeight <= 0 {
            throw ValidationError("--seed-cell-height must be positive.")
        }
    }

    /// Shared `--point` range check, delegated to by the top-level
    /// forwarder. `CoordinatePair` already enforces the `x,y` grammar
    /// and finiteness at parse time; hit-testing additionally only
    /// makes sense for non-negative screen coordinates.
    public static func validatePoint(_ point: CoordinatePair?) throws {
        if let point, point.x < 0 || point.y < 0 {
            throw ValidationError("--point coordinates must be non-negative.")
        }
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await performGlobalSetup(logger: logger)

        let parsedPoint = point.map { AccessibilityPoint(x: $0.x, y: $0.y) }
        let fetchResult = try await AccessibilityFetcher.fetchAccessibilityInfo(
            for: device.resolved,
            point: parsedPoint,
            logger: logger,
            maxProbes: maxProbes,
            minCellSize: minCellSize,
            seedCellWidth: seedCellWidth,
            seedCellHeight: seedCellHeight
        )
        let jsonData = fetchResult.data
        // Only build the JSONValue tree when the client will actually
        // see it. On a complex screen the parse is ~30 ms and shuffling
        // it across the daemon socket adds another ~80 ms. `outline` +
        // `entries` cover every other consumer.
        let tree: JSONValue? = (jsonOutput && !noRaw) ? try JSONValue.decode(from: jsonData) : nil

        // Decode the same bytes into the typed tree for outline rendering.
        // `--point` returns a single element object instead of a root
        // array, so try the array shape first and fall back to a single
        // element wrapped in a one-item array. Decoding errors here do
        // not abort the command — a malformed or unexpectedly-shaped
        // tree still produces useful `--json` output, and the outline
        // degrades to just the header.
        let decoder = JSONDecoder()
        let typedTree: [AccessibilityElement]
        if let roots = try? decoder.decode([AccessibilityElement].self, from: jsonData) {
            typedTree = roots
        } else if let root = try? decoder.decode(AccessibilityElement.self, from: jsonData) {
            typedTree = [root]
        } else {
            typedTree = []
        }
        // Foreground app's CFBundleIdentifier — best-effort. Empty
        // string means resolution failed (no pid in tree, simctl
        // unreachable, system root, etc.); consumers treat appPackage
        // as a hint. Resolved *before* rendering so the outline header
        // can be reconciled against the real foreground app rather than
        // the (possibly stale/empty) AX-root label (issue #81). Reuses
        // the daemon's just-taken liveness snapshot to avoid a second
        // `launchctl` spawn when the root pid is already known.
        let appPackage = BundleIdentifierResolver.resolve(
            udid: device.resolved,
            rootElement: typedTree.first,
            cachedSnapshot: DaemonDispatch.lastLivenessSnapshot
        )
        let orientation = fetchResult.calibration?.orientation
        let outline = OutlineFormatter.render(
            tree: typedTree,
            foregroundBundleId: appPackage.isEmpty ? nil : appPackage,
            // Portrait keeps the legacy header byte-for-byte; only a
            // rotated screen earns the tag.
            orientationTag: orientation.flatMap { $0 == .portrait ? nil : $0.rawValue }
        )

        // Alias cache is best-effort: a write failure (permissions, full
        // disk) must not prevent the user from seeing the snapshot.
        // `--point` results never persist — a one-element subtree would
        // clobber the full-screen @N table the next tap resolves against.
        if parsedPoint == nil {
            do {
                try OutlineCache.write(
                    outline: outline,
                    udid: device.resolved,
                    orientation: orientation?.rawValue
                )
            } catch {
                logger.info().log("Failed to write outline cache: \(error.localizedDescription)")
            }
        }

        return ExecutionResult(
            platform: "ios",
            raw: tree,
            outline: outline.text,
            entries: outline.entries,
            lists: outline.lists,
            screen: outline.screen,
            appLabel: outline.appLabel,
            appPackage: appPackage,
            orientation: orientation?.rawValue,
            // Degraded calibration (guessed orientation) must reach the
            // caller: the outline may have lost regions to mis-mapped
            // recovery probes and `orientation` is a guess, not a fact.
            commandAdvisory: fetchResult.calibration?.advisory
        )
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        // `result.outline` already ends in `\n`, so emit it raw rather
        // than going through `.line(_:)` which would add a second.
        .raw(result.outline)
    }
}