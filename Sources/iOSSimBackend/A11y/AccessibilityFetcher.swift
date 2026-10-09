// SPDX-License-Identifier: Apache-2.0
import CompanionUtilities
import FBControlCore
import FBSimulatorControl
import Foundation
import SimUseCore

public struct AccessibilityPoint: Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

// MARK: - Accessibility Fetcher

@MainActor
public struct AccessibilityFetcher {
    /// Tree (or point-query) payload plus the orientation calibration the
    /// fetch ran under. `calibration` is nil only for surfaces that never
    /// calibrated (legacy shims); a degraded calibration is still present
    /// with its advisory attached. `advisory` is non-nil when the tree came
    /// back as an empty shell and the visible elements were recovered from
    /// other processes via the remote-content retry (issue #64).
    public struct FetchResult {
        public let data: Data
        public let calibration: OrientationCalibration?
        public let advisory: CommandAdvisory?
        /// Non-nil when the fetch ran under an active resizable app
        /// session (issue #143): the tree is the frontmost app's own, but
        /// calibration and collapsed-children recovery were skipped
        /// because the hit-test resolves on the main display.
        public let resizableSession: ResizableAppSession?

        public init(
            data: Data,
            calibration: OrientationCalibration?,
            advisory: CommandAdvisory? = nil,
            resizableSession: ResizableAppSession? = nil
        ) {
            self.data = data
            self.calibration = calibration
            self.advisory = advisory
            self.resizableSession = resizableSession
        }
    }

    public static func fetchAccessibilityInfoJSONData(
        for simulatorUDID: String,
        point: AccessibilityPoint? = nil,
        logger: SimUseLogger,
        maxProbes: Int = 300,
        minCellSize: Double = 14,
        seedCellWidth: Double = 160,
        seedCellHeight: Double = 80
    ) async throws -> Data {
        try await fetchAccessibilityInfo(
            for: simulatorUDID,
            point: point,
            logger: logger,
            maxProbes: maxProbes,
            minCellSize: minCellSize,
            seedCellWidth: seedCellWidth,
            seedCellHeight: seedCellHeight
        ).data
    }

    public static func fetchAccessibilityInfo(
        for simulatorUDID: String,
        point: AccessibilityPoint? = nil,
        logger: SimUseLogger,
        maxProbes: Int = 300,
        minCellSize: Double = 14,
        seedCellWidth: Double = 160,
        seedCellHeight: Double = 80
    ) async throws -> FetchResult {
        let perf = PerfLog.start()

        let simulatorSet = try await getSimulatorSet(
            deviceSetPath: nil,
            logger: logger,
            reporter: EmptyEventReporter.shared
        )
        perf.stage("getSimulatorSet")

        guard let target = simulatorSet.allSimulators.first(where: { $0.udid == simulatorUDID }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(simulatorUDID) not found in set.")
        }
        perf.stage("sim lookup")

        let native = NativePortraitSize(screenInfo: target.screenInfo)
        let probe: CollapsedChildrenRecovery.PointProbe = { point in
            let start = DispatchTime.now()
            // `nestedFormat: false` — probes only need the topmost hit's own
            // frame / role / label for dedup; the nested subtree is dropped
            // because every probed hit is tagged synthesized and never
            // re-walked into its children anyway. Cuts per-probe XPC cost
            // significantly on WebView-heavy pages.
            let raw: AnyObject = try await target.legacyAccessibilityElement(at: point, nestedFormat: false)
            let durationMs = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
            perf.recordProbe(durationMs: durationMs, phase: "objectAtPoint")
            return raw as? [String: Any]
        }

        if let point {
            // Resizable app session (issue #143): the hit-test answers for
            // the main display (SpringBoard) during a session, whatever the
            // point. No tree to corroborate with here, so the cached answer
            // is taken as-is.
            let resizableSession = await ResizableAppSessionMonitor.shared.state(for: simulatorUDID).session
            perf.stage("resizable session check")
            return try await pointQuery(
                target: target,
                point: point,
                native: native,
                resizableSession: resizableSession,
                probe: probe,
                logger: logger,
                perf: perf
            )
        }

        var info: AnyObject = try await target.legacyAccessibilityElements(nestedFormat: true)
        perf.stage("tree fetch XPC")

        // Resizable app session (Xcode 27 Resize Mode, issue #143): the
        // frontmost app renders on the virtual "Resizable" display while
        // the point hit-test XPC resolves on the main display, where
        // SpringBoard is frontmost. Every hit-test driven step below —
        // calibration probes, collapsed-children recovery — would
        // therefore describe SpringBoard, not the app. The monitor caches
        // the ~0.3 s devicectl query; a root frame that is neither the
        // device's portrait size nor its landscape swap is in-band
        // evidence of a session and bypasses a cached "no session", so a
        // session started moments ago is seen now rather than after the
        // TTL. (A scene at exactly the device's size has no such evidence
        // and waits for the TTL — the documented gap.)
        let sceneLooksResized = Self.sceneSizeIsNotADeviceSize(info: info, native: native)
        let resizableSession = await ResizableAppSessionMonitor.shared
            .state(for: simulatorUDID, refreshIfInactive: sceneLooksResized)
            .session
        perf.stage("resizable session check")
        if let resizableSession {
            logger.info().log("Resizable app session active (\(resizableSession.displayName) \(resizableSession.preferredSizeDescription)); hit-test driven recovery and calibration are skipped")
        } else if sceneLooksResized {
            logger.info().log("AX root frame is not a device size but CoreDevice reports no resizable app session; proceeding normally")
        }

        // Empty-shell retry (issue #64): a remote-process presentation
        // (system document picker) leaves the frontmost tree a bare,
        // frameless AXApplication. Refetch once with upstream's
        // remote-content discovery so the visible cross-process elements
        // materialize. The plain first fetch keeps the hot path untouched —
        // healthy and sparse-but-valid trees never pay for the grid probes.
        // Skipped under a resizable app session: the retry's grid
        // hit-tests would collect SpringBoard's elements from the main
        // display, which is the splicing this path exists to avoid.
        var remoteAdvisory: CommandAdvisory? = nil
        if resizableSession == nil, isEmptyShellTree(info) {
            logger.info().log("Frontmost accessibility tree is an empty shell; retrying with remote-content discovery")
            let samplingScale = native.map { uiScaleFromRawTree(info, native: $0) } ?? .identity
            if let retried = try? await target.legacyAccessibilityElements(
                    nestedFormat: true,
                    includeRemoteContent: true,
                    remoteSamplingRegion: remoteContentSamplingRegion(native: native, uiScale: samplingScale)),
               !isEmptyShellTree(retried) {
                info = retried
                remoteAdvisory = CommandAdvisory(
                    kind: .remoteContentRecovery,
                    message: "The frontmost app exposed an empty accessibility tree; visible elements were recovered from other processes (e.g. a system picker). The hierarchy is flat and may not cover every element — prefer visible labels over structure."
                )
            } else {
                logger.info().log("Remote-content retry did not surface any elements; keeping the original tree")
            }
            perf.stage("remote-content retry")
        }

        if let resizableSession {
            // The raw tree is the app's own and its frames are scene
            // space, so it is returned as fetched: identity calibration
            // (a resized scene's size says nothing about rotation, and
            // the probes would land on SpringBoard anyway) and no
            // recovery walk (whose synthesized children would be
            // SpringBoard's — the splicing the issue reports).
            let display = rawDisplayFrame(in: rawRoots(of: info))
            let advisory = ResizableAppSessionAdvisory.describeUI(
                session: resizableSession,
                sceneSize: display.map { (width: $0.width, height: $0.height) },
                native: native
            )
            let data = try serializeAccessibilityInfo(info)
            perf.stage("serialize")
            perf.finish()
            return FetchResult(
                data: data,
                calibration: .identity(native: native),
                advisory: CommandAdvisory.merged([remoteAdvisory, advisory].compactMap { $0 }),
                resizableSession: resizableSession
            )
        }

        let calibration = await calibrate(info: info, native: native, probe: probe, logger: logger)
        perf.stage("calibrate")

        // AX frames are UI-space while the hit-test consumes points on
        // the native-portrait AXES (issue #34; the metric stays UI —
        // see `probeCGPoint`) — cross the boundary here so the
        // quadtree's UI-space bookkeeping stays untouched. Portrait
        // keeps the exact pre-fix closure.
        let recoveryProbe = calibration.wrappedProbe(probe)

        let recovered = try await CollapsedChildrenRecovery.recover(
            in: info,
            probe: recoveryProbe,
            logger: logger,
            maxProbes: maxProbes,
            minCellSize: minCellSize,
            seedCellWidth: seedCellWidth,
            seedCellHeight: seedCellHeight,
            perf: perf
        )
        perf.stage("recover walk")

        let data = try serializeAccessibilityInfo(recovered)
        perf.stage("serialize")
        perf.finish()
        return FetchResult(data: data, calibration: calibration, advisory: remoteAdvisory)
    }

    /// Whether a fetched tree payload is an "empty shell" warranting the
    /// remote-content retry (issue #64): no non-application node anywhere
    /// in it carries a positive-area frame. The frontmost app reports
    /// exactly this while a remote process (system document picker) owns
    /// the visible UI — observed live both as a bare `{pid, role}` root
    /// (0.10.0-era reports) and as a full-screen-framed AXApplication
    /// with zero children (current runtimes). The application container's
    /// own frame is just the screen rectangle and proves nothing about
    /// visible content, so it never vetoes the retry. Unrecognized shapes
    /// and oversized trees are NOT shells: failing closed keeps the retry
    /// (and its full-screen probe cost) off every path this predicate
    /// doesn't positively understand.
    /// The grid-sampling region for the remote-content retry: the
    /// hit-test canvas in portrait bounds. Upstream's default region is
    /// the root element's UI-space frame, but the grid points feed the
    /// point hit-test, which consumes UI-METRIC points on native-portrait
    /// AXES (see `NativePortraitSize.uiMetric`) — under rotation a
    /// UI-space region samples the wrong band (points past the portrait
    /// width hit nothing; a whole band is never sampled). A full
    /// portrait-bounds grid covers every visible pixel regardless of
    /// orientation. On display-downscaled devices those bounds are the
    /// UI-sized canvas (375x812 on the mini, not pixels/scale): a
    /// 360x780 grid would never probe the right/bottom ~4% of the
    /// screen, exactly where a picker's bottom bar tends to live. Nil
    /// (unknown screen size) falls back to upstream's default region:
    /// correct in portrait, best-effort elsewhere.
    nonisolated static func remoteContentSamplingRegion(
        native: NativePortraitSize?,
        uiScale: UIPointScale = .identity
    ) -> CGRect? {
        native.map { n in
            let canvas = n.uiMetric(uiScale)
            return CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        }
    }

    /// `UIPointScale` recovered from a raw (possibly shell) tree before
    /// calibration has run. An empty-shell root still carries its
    /// full-screen display frame on current runtimes — exactly the UI
    /// screen size the scale needs. Bare shells (no framed root) yield
    /// identity, i.e. the pre-scale sampling behaviour.
    nonisolated static func uiScaleFromRawTree(
        _ info: AnyObject,
        native: NativePortraitSize
    ) -> UIPointScale {
        let display = rawDisplayFrame(in: rawRoots(of: info))
        return OrientationCalibrator.uiPointScale(
            native: native,
            uiScreenSize: display.map { (width: $0.width, height: $0.height) }
        )
    }

    nonisolated static func isEmptyShellTree(_ info: AnyObject) -> Bool {
        let roots: [[String: Any]]
        if let array = info as? [[String: Any]] {
            roots = array
        } else if let dict = info as? [String: Any] {
            roots = [dict]
        } else {
            return false
        }
        var stack = roots
        var visited = 0
        while let node = stack.popLast() {
            visited += 1
            if visited > 500 {
                // A tree this large is definitionally not a shell.
                return false
            }
            let isApplication = (node["role"] as? String) == "AXApplication"
                || (node["type"] as? String) == "Application"
            if !isApplication, OrientationCalibrator.frameRect(of: node) != nil {
                return false
            }
            if let children = node["children"] as? [[String: Any]] {
                stack.append(contentsOf: children)
            }
        }
        return true
    }

    public static func fetchAccessibilityElements(
        for simulatorUDID: String,
        logger: SimUseLogger
    ) async throws -> [AccessibilityElement] {
        try await fetchAccessibilityElementsWithCalibration(for: simulatorUDID, logger: logger).roots
    }

    public static func fetchAccessibilityElementsWithCalibration(
        for simulatorUDID: String,
        logger: SimUseLogger
    ) async throws -> (roots: [AccessibilityElement], calibration: OrientationCalibration?) {
        let result = try await fetchAccessibilityInfo(for: simulatorUDID, point: nil, logger: logger)
        let decoder = JSONDecoder()

        // The root shape is normally an array of elements (nested-format output
        // wraps the root in `[app]`), but the single-root fallback survives for
        // point-query style inputs. Only the array-vs-dict shape mismatch at the
        // root should trigger the fallback; any other decoding error must bubble
        // up so we don't silently hide real bugs in element decoding.
        do {
            return (try decoder.decode([AccessibilityElement].self, from: result.data), result.calibration)
        }
        catch let DecodingError.typeMismatch(_, context) where context.codingPath.isEmpty {
            let root = try decoder.decode(AccessibilityElement.self, from: result.data)
            return ([root], result.calibration)
        }
    }

    // MARK: - Point query (UI-space semantics)

    /// `--point` coordinates are UI space — the space every printed frame
    /// uses. The hit-test XPC consumes points on native-portrait axes,
    /// so a rotated device needs the query transformed. The first probe doubles as
    /// calibration evidence: its returned frame settles the orientation
    /// only when exactly one candidate maps the probe point into it. Any
    /// tie (a fat frame containing several projections proves nothing)
    /// falls through to a full tree calibration — giving portrait the tie
    /// would return the wrong element on rotated devices.
    ///
    /// The hit-test consumes UI-METRIC points on native-portrait axes
    /// (verified live on a display-downscaled iPhone 12 mini — see
    /// `NativePortraitSize.uiMetric`), so in portrait the identity probe
    /// queries the exact requested point on every device, downscaled or
    /// not, and the fast path stays single-probe. Only the HID dispatch
    /// side of a calibration carries the `UIPointScale`.
    ///
    /// One deliberate gap: the fast path's bounds gate below compares
    /// against the native (pixels/scale) portrait size, because no scale
    /// is known before a tree is fetched. On a downscaled panel, points
    /// in the UI-only edge bands (x in 360..<375, y in 780..<812 on the
    /// mini) skip the identity probe and take the tree-calibration
    /// fallback — same result, one tree fetch slower. Widening the gate
    /// would not help: `soleOrientation` clamps its projections to the
    /// native canvas, so a probe out there could never settle anything.
    private static func pointQuery(
        target: FBSimulator,
        point: AccessibilityPoint,
        native: NativePortraitSize?,
        resizableSession: ResizableAppSession? = nil,
        probe: @escaping CollapsedChildrenRecovery.PointProbe,
        logger: SimUseLogger,
        perf: PerfLog
    ) async throws -> FetchResult {
        func nestedQuery(_ p: CGPoint) async throws -> AnyObject {
            try await target.legacyAccessibilityElement(at: p, nestedFormat: true)
        }
        // Under a resizable app session the hit-test answers for the main
        // display (SpringBoard), whatever the point — say so rather than
        // let the caller mistake it for the app (issue #143).
        let sessionAdvisory = resizableSession.map(ResizableAppSessionAdvisory.pointQuery)

        guard let native else {
            // No screen info — keep the legacy raw-space behavior.
            let info = try await nestedQuery(point.cgPoint)
            perf.stage("point XPC")
            let data = try serializeAccessibilityInfo(info)
            perf.finish()
            return FetchResult(data: data, calibration: .identity(), advisory: sessionAdvisory, resizableSession: resizableSession)
        }

        var orientation: DisplayOrientation? = nil
        var identityResult: AnyObject? = nil
        var calibration: OrientationCalibration? = nil

        if resizableSession != nil {
            // Nothing to calibrate against: the probe canvas is the main
            // display, and a resized scene's size says nothing about
            // rotation. Query the raw point and skip the tree calibration.
            orientation = .portrait
        }

        if point.x < native.width, point.y < native.height {
            if let raw = try? await nestedQuery(point.cgPoint) {
                perf.stage("point XPC")
                identityResult = raw
                if resizableSession == nil,
                   let dict = raw as? [String: Any],
                   let frame = OrientationCalibrator.frameRect(of: dict) {
                    orientation = OrientationCalibrator.soleOrientation(
                        mapping: point.cgPoint, into: frame, native: native
                    )
                }
            }
        }
        // A UI point outside the native portrait bounds can only exist in
        // a landscape UI — the identity probe was skipped above and the
        // tree calibration below settles which landscape.

        if orientation == nil {
            if let info: AnyObject = try? await target.legacyAccessibilityElements(nestedFormat: true) {
                perf.stage("tree fetch XPC (point calibration)")
                let treeCalibration = await calibrate(info: info, native: native, probe: probe, logger: logger)
                calibration = treeCalibration
                orientation = treeCalibration.orientation
            }
        }

        let resolved = orientation ?? .portrait
        // `orientation == nil` here means both the identity probe and the
        // tree-fetch calibration failed to settle anything — that is a
        // degraded portrait guess, not a clean single-probe confirmation,
        // and must say so.
        let finalCalibration = calibration ?? OrientationCalibration(
            orientation: resolved,
            native: native,
            probesUsed: 1,
            advisory: orientation == nil
                ? CommandAdvisory(
                    kind: .orientationCalibrationFallback,
                    message: "Orientation could not be confirmed for the point query; assuming portrait. The result may be wrong if the device is rotated."
                )
                : nil
        )

        let info: AnyObject
        // The hit-test consumes UI-METRIC points on native-portrait
        // axes, so the portrait probe transform is the identity even on
        // display-downscaled devices — the identity probe already
        // queried the right point and its result is reusable. Rotated
        // devices re-issue through `probeCGPoint` (axes only, never the
        // HID metric scale).
        if resolved == .portrait, let identityResult {
            info = identityResult
        } else {
            info = try await nestedQuery(finalCalibration.probeCGPoint(point.cgPoint))
            perf.stage("point XPC (transformed)")
        }
        let data = try serializeAccessibilityInfo(info)
        perf.stage("serialize")
        perf.finish()
        // The calibration advisory reaches callers through
        // `calibration.advisory`; only the session one rides here.
        return FetchResult(
            data: data,
            calibration: finalCalibration,
            advisory: sessionAdvisory,
            resizableSession: resizableSession
        )
    }

    /// Orientation calibration WITHOUT the collapsed-children recovery
    /// walk — for verbs that need the current orientation but not the
    /// tree itself (directional gesture presets, issue #66). Costs one
    /// tree-fetch XPC plus at most `OrientationCalibrator.defaultMaxProbes`
    /// hit-test probes; recovery's quadtree probing (up to hundreds of
    /// XPC round-trips on WebView-heavy screens) is skipped entirely.
    public static func fetchOrientationCalibration(
        for simulatorUDID: String,
        logger: SimUseLogger
    ) async throws -> OrientationCalibration {
        let simulatorSet = try await getSimulatorSet(
            deviceSetPath: nil,
            logger: logger,
            reporter: EmptyEventReporter.shared
        )
        guard let target = simulatorSet.allSimulators.first(where: { $0.udid == simulatorUDID }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(simulatorUDID) not found in set.")
        }
        let native = NativePortraitSize(screenInfo: target.screenInfo)
        let probe: CollapsedChildrenRecovery.PointProbe = { point in
            let raw: AnyObject = try await target.legacyAccessibilityElement(at: point, nestedFormat: false)
            return raw as? [String: Any]
        }
        let info: AnyObject = try await target.legacyAccessibilityElements(nestedFormat: true)
        return await calibrate(info: info, native: native, probe: probe, logger: logger)
    }

    // MARK: - Calibration over the raw tree payload

    private static func calibrate(
        info: AnyObject,
        native: NativePortraitSize?,
        probe: @escaping CollapsedChildrenRecovery.PointProbe,
        logger: SimUseLogger
    ) async -> OrientationCalibration {
        let roots = rawRoots(of: info)
        let display = rawDisplayFrame(in: roots)
        return await OrientationCalibrator.calibrate(
            native: native,
            uiScreenSize: display.map { (width: $0.width, height: $0.height) },
            discriminators: rawDiscriminatorRects(in: roots, display: display),
            probe: probe,
            logger: logger
        )
    }

    private nonisolated static func rawRoots(of info: AnyObject) -> [[String: Any]] {
        if let array = info as? [[String: Any]] { return array }
        if let dict = info as? [String: Any] { return [dict] }
        return []
    }

    /// Whether the raw tree's display frame matches neither the device's
    /// portrait size nor its landscape swap (±1 pt, like
    /// `OrientationCalibrator.orderedCandidates`). True for a resized
    /// scene at any size other than the device's own; false — no
    /// evidence either way — when the tree has no framed root or the
    /// screen info is unknown.
    nonisolated static func sceneSizeIsNotADeviceSize(info: AnyObject, native: NativePortraitSize?) -> Bool {
        guard let native, let display = rawDisplayFrame(in: rawRoots(of: info)) else { return false }
        func matches(_ width: Double, _ height: Double) -> Bool {
            abs(display.width - width) <= 1 && abs(display.height - height) <= 1
        }
        return !matches(native.width, native.height) && !matches(native.height, native.width)
    }

    /// Raw-payload mirror of `AXDisplayFrame.frame(in:)`: the largest
    /// positive-area Application-typed root, falling back to the largest
    /// root of any type.
    private nonisolated static func rawDisplayFrame(in roots: [[String: Any]]) -> CGRect? {
        let usable = roots.compactMap { root -> (isApplication: Bool, rect: CGRect)? in
            guard let rect = OrientationCalibrator.frameRect(of: root) else { return nil }
            let type = root["type"] as? String
            let role = root["role"] as? String
            return (type == "Application" || role == "AXApplication", rect)
        }
        let applications = usable.filter(\.isApplication)
        let pool = applications.isEmpty ? usable : applications
        return pool.max { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?.rect
    }

    /// Off-center element frames from a bounded walk of the raw tree —
    /// calibration needs a handful of asymmetric rects, not the full tree.
    private static func rawDiscriminatorRects(
        in roots: [[String: Any]],
        display: CGRect?,
        nodeBudget: Int = 500,
        limit: Int = 40
    ) -> [CGRect] {
        var rects: [CGRect] = []
        var visited = 0
        var queue = roots
        while !queue.isEmpty, visited < nodeBudget {
            let node = queue.removeFirst()
            visited += 1
            let type = node["type"] as? String
            let role = node["role"] as? String
            if type != "Application", role != "AXApplication",
               let rect = OrientationCalibrator.frameRect(of: node) {
                rects.append(rect)
            }
            if let children = node["children"] as? [[String: Any]] {
                queue.append(contentsOf: children)
            }
        }
        guard let display else { return Array(rects.prefix(limit)) }
        let cx = display.midX
        let cy = display.midY
        func distanceSquared(_ r: CGRect) -> Double {
            let dx = r.midX - cx
            let dy = r.midY - cy
            return dx * dx + dy * dy
        }
        return rects
            .sorted { distanceSquared($0) > distanceSquared($1) }
            .prefix(limit)
            .map { $0 }
    }

    private static func serializeAccessibilityInfo(_ accessibilityInfo: AnyObject) throws -> Data {
        if let nsDict = accessibilityInfo as? NSDictionary {
            return try JSONSerialization.data(withJSONObject: nsDict, options: [.prettyPrinted])
        }
        if let nsArray = accessibilityInfo as? NSArray {
            return try JSONSerialization.data(withJSONObject: nsArray, options: [.prettyPrinted])
        }

        throw CLIError(errorDescription: "Accessibility info was not a dictionary or array as expected.")
    }
}

// MARK: - Collapsed Children Recovery
//
// Some UIKit containers — notably UITabBar — report an empty
// `accessibilityChildren` list through AXPTranslator, even though their
// descendants are still live accessibility elements reachable via
// `objectAtPoint:` (hit-test). Investigation (LINEIOS-216136) confirmed that
// hit-testing is the only structurally available primitive for recovering
// those children.
//
// This module walks the returned tree and runs the hit-fed quadtree
// refinement from LINEIOS-216144 in two complementary passes:
//
//   Phase 1 — empty-AXGroup recovery. An AXGroup that passes `shouldProbe`
//   but has no children has its entire frame seeded with s₀×s₀ cells and
//   drained by the orchestrator.
//
//   Phase 2 — blind-zone recovery. Any container whose direct children
//   leave a significant rectangular gap inside its frame has that gap
//   seeded and drained. Hits that fall inside (or equal) an existing
//   child's frame are rejected as descendants of a known element.
//
// Both phases share a single global probe budget and populate their own
// `CoveredSet`, so probes inside already-discovered elements are skipped
// without an XPC round trip. Synthesized entries are tagged
// `"synthesized": true` so downstream consumers can tell them apart from
// natively-reported children.
//
// For 1-D row shapes (the UITabBar case) phase 1 degrades gracefully to
// the behaviour of the original midline sampler: seed cells line up along
// the single row, remainders fall below s_min quickly, and adjacent
// duplicate hits are filtered by the centre-in-CoveredSet check.
@MainActor
public enum CollapsedChildrenRecovery {
    /// Resolves the accessibility element at a given screen point. Returning
    /// `nil` (or throwing) causes that sample point to be skipped. Extracted so
    /// the logic can be unit-tested without a booted simulator.
    public typealias PointProbe = (CGPoint) async throws -> [String: Any]?

    // Eligibility gate for phase 1 (unchanged external contract).
    public static let minContainerWidth: Double = 100
    public static let minContainerHeight: Double = 30

    // Quadtree refinement parameters.
    // Seed cells are rectangular (wider than tall) to match the typical
    // UI element aspect ratio — nav links, headlines, cells, text rows are
    // almost always landscape. A square seed wastes Y-resolution on rows
    // where the real thing is 18-40 pt tall; a shorter seed catches them
    // without doubling X probes.
    public static let defaultSeedCellWidth: Double = 160
    public static let defaultSeedCellHeight: Double = 80
    // Kept for backward compat / the ladder description. seedCellWidth is
    // the canonical "s₀" the design doc refers to.
    public static let seedCellSize: Double = defaultSeedCellWidth
    public static let coverageTerminationRatio: Double = 0.95

    // Phase 2 thresholds. A gap rectangle between siblings must clear both
    // `minBlindZoneMinDim` on each side and `minBlindZoneArea` in total to
    // qualify — enough to host a plausible accessibility element rather
    // than inter-element padding.
    public static let minBlindZoneMinDim: Double = 60
    public static let minBlindZoneArea: Double = 10_000

    // Defaults chosen empirically on LINE Dev News tab: 300 probes @ 20pt
    // min cell cover the WebView blind zone end-to-end at ~1 s warm
    // latency. Callers (including the CLI) can override both knobs when a
    // denser / sparser sweep trade-off is warranted.
    public static let defaultMaxProbes: Int = 300
    public static let defaultMinCellSize: Double = 14

    public static func recover(
        in info: AnyObject,
        probe: @escaping PointProbe,
        logger: SimUseLogger,
        maxProbes: Int = 300,
        minCellSize: Double = 14,
        seedCellWidth: Double = 160,
        seedCellHeight: Double = 80,
        scanBlindZones: Bool = true,
        perf: PerfLog? = nil
    ) async throws -> AnyObject {
        guard let rootArray = info as? NSArray else { return info }

        let budget = ProbeBudget(maxProbes)
        let tuning = Tuning(
            minCellSize: max(1, minCellSize),
            seedCellWidth: max(1, seedCellWidth),
            seedCellHeight: max(1, seedCellHeight)
        )
        // Traversal-scoped identity set. Pre-seeded with every original-tree
        // node so a probe hit that collides with a natively-exposed element
        // is dropped, and shared across every runProbes call so sibling
        // AXGroup wrappers do not each synthesize their own copy of the
        // same on-screen element (LINEIOS-216286).
        let seen = SeenIdentitySet()
        var mutated: [[String: Any]] = []
        mutated.reserveCapacity(rootArray.count)
        for element in rootArray {
            guard let node = element as? [String: Any] else {
                // Unrecognized shape — keep the walk lossless and abort recovery
                return info
            }
            prepopulateSeen(seen, from: node)
        }
        for element in rootArray {
            guard let node = element as? [String: Any] else { return info }
            try mutated.append(
                await walk(
                    node: node,
                    probe: probe,
                    logger: logger,
                    budget: budget,
                    tuning: tuning,
                    seen: seen,
                    scanBlindZones: scanBlindZones,
                    perf: perf
                )
            )
        }
        return mutated as NSArray
    }

    /// Identity key for cross-parent dedup of synthesized hits. Returns `nil`
    /// for nodes without a usable frame (missing or zero-sized) — those are
    /// typically UIKit placeholder artifacts whose identity is ambiguous and
    /// that should not enter the global dedup set.
    public static func identityKey(for node: [String: Any]) -> String? {
        guard let frameStr = node["AXFrame"] as? String, !frameStr.isEmpty else {
            return nil
        }
        if let f = frameTuple(of: node), f.width <= 0 || f.height <= 0 {
            return nil
        }
        let role = (node["role"] as? String) ?? ""
        let label = (node["AXLabel"] as? String) ?? ""
        return "\(frameStr)|\(role)|\(label)"
    }

    private static func prepopulateSeen(_ seen: SeenIdentitySet, from node: [String: Any]) {
        if let key = identityKey(for: node) {
            seen.insert(key)
        }
        if let kids = node["children"] as? [[String: Any]] {
            for child in kids {
                prepopulateSeen(seen, from: child)
            }
        }
    }

    /// Bundle of runtime-tunable knobs. Kept as a struct so new knobs can
    /// join without churning the walk / runProbes signatures.
    public struct Tuning {
        public let minCellSize: Double
        public let seedCellWidth: Double
        public let seedCellHeight: Double
        public var minRemainderArea: Double { minCellSize * minCellSize }
        /// Cap on how many times a nil probe may trigger quadrant
        /// refinement within a single `runProbes` call. The uncapped
        /// cascade (1 → 4 → 16 → 64) multiplies budget pressure on
        /// genuinely empty space while rarely uncovering a hidden
        /// element. These caps roughly match what a WebView-dense page
        /// needs and keep sparse UIKit screens from bleeding the whole
        /// budget into empty gaps.
        public let phase1NilRefineCap: Int = 16
        public let phase2NilRefineCap: Int = 6
    }

    private static func walk(
        node: [String: Any],
        probe: PointProbe,
        logger: SimUseLogger,
        budget: ProbeBudget,
        tuning: Tuning,
        seen: SeenIdentitySet,
        scanBlindZones: Bool,
        perf: PerfLog?
    ) async throws -> [String: Any] {
        var node = node

        let existing = (node["children"] as? [[String: Any]]) ?? []
        var children: [[String: Any]] = []
        children.reserveCapacity(existing.count)
        for child in existing {
            try children.append(
                await walk(
                    node: child,
                    probe: probe,
                    logger: logger,
                    budget: budget,
                    tuning: tuning,
                    seen: seen,
                    scanBlindZones: scanBlindZones,
                    perf: perf
                )
            )
        }

        // Phase 1 — probe empty AXGroups.
        if children.isEmpty, shouldProbe(node) {
            let synthesized = try await runProbes(
                parent: node,
                seedRegions: nil,
                existingChildren: [],
                probe: probe,
                logger: logger,
                budget: budget,
                tuning: tuning,
                seen: seen,
                perf: perf
            )
            for probed in synthesized {
                try children.append(
                    await walk(
                        node: probed,
                        probe: probe,
                        logger: logger,
                        budget: budget,
                        tuning: tuning,
                        seen: seen,
                        scanBlindZones: scanBlindZones,
                        perf: perf
                    )
                )
            }
        }

        // Phase 2 — probe significant blind zones between siblings.
        if scanBlindZones,
           !children.isEmpty,
           let region = rect(of: node),
           region.width >= minContainerWidth,
           region.height >= minContainerHeight {
            let childFrames = children.compactMap { rect(of: $0) }
            let blindZones = computeBlindZones(in: region, coveredBy: childFrames)
                .filter { zone in
                    min(zone.width, zone.height) >= CGFloat(minBlindZoneMinDim)
                    && zone.width * zone.height >= CGFloat(minBlindZoneArea)
                }
            if !blindZones.isEmpty {
                let discovered = try await runProbes(
                    parent: node,
                    seedRegions: blindZones,
                    existingChildren: children,
                    probe: probe,
                    logger: logger,
                    budget: budget,
                    tuning: tuning,
                    seen: seen,
                    perf: perf
                )
                for probed in discovered {
                    try children.append(
                        await walk(
                            node: probed,
                            probe: probe,
                            logger: logger,
                            budget: budget,
                            tuning: tuning,
                            seen: seen,
                            scanBlindZones: scanBlindZones,
                            perf: perf
                        )
                    )
                }
            }
        }

        node["children"] = children
        return node
    }

    public static func shouldProbe(_ node: [String: Any]) -> Bool {
        // Only AXGroup containers — the shape AXPTranslator collapses.
        guard (node["role"] as? String) == "AXGroup" else { return false }
        // Skip anything we synthesized ourselves to avoid re-probing the same frame.
        if (node["synthesized"] as? Bool) == true { return false }
        guard let f = frameTuple(of: node),
              f.width >= minContainerWidth,
              f.height >= minContainerHeight else {
            return false
        }
        return true
    }

    /// Core quadtree orchestrator. Used by both phases:
    /// - Phase 1 passes `seedRegions == nil` and `existingChildren == []` so
    ///   the entire parent frame is seeded.
    /// - Phase 2 passes `seedRegions` = blind-zone rectangles and
    ///   `existingChildren` = the parent's direct children so their frames
    ///   pre-populate the CoveredSet and dedup sets.
    private static func runProbes(
        parent: [String: Any],
        seedRegions: [CGRect]?,
        existingChildren: [[String: Any]],
        probe: PointProbe,
        logger: SimUseLogger,
        budget: ProbeBudget,
        tuning: Tuning,
        seen: SeenIdentitySet,
        perf: PerfLog?
    ) async throws -> [[String: Any]] {
        guard let region = rect(of: parent) else { return [] }
        let parentFrameStr = (parent["AXFrame"] as? String) ?? ""
        let slack: CGFloat = 1.0
        let regionArea = region.width * region.height
        let coverageTarget = regionArea * CGFloat(coverageTerminationRatio)

        var queue = WorkQueue()
        let childFrames: [CGRect] = existingChildren.compactMap { rect(of: $0) }
        var covered: [CGRect] = childFrames
        // Identity dedup is handled by the traversal-scoped `seen` set (pre-
        // seeded with every original-tree node at the top of `recover`). The
        // local per-parent `covered` array stays — geometric containment is a
        // separate axis from identity and still guards phase 2 descendant
        // overlap.
        var hits: [[String: Any]] = []
        var coveredArea: CGFloat = 0
        var nilRefineCount = 0

        // Seed cells. When `seedRegions == nil` (phase 1) we treat the full
        // parent frame as the seed area. Otherwise each provided rectangle
        // contributes its own grid of cells, intersected with the region so
        // cells never straddle the container boundary.
        let cellW = CGFloat(tuning.seedCellWidth)
        let cellH = CGFloat(tuning.seedCellHeight)
        let regions = seedRegions ?? [region]
        for seed in regions {
            let clipped = seed.intersection(region)
            if clipped.isNull || clipped.isEmpty { continue }
            let cols = max(1, Int((clipped.width / cellW).rounded(.up)))
            let rows = max(1, Int((clipped.height / cellH).rounded(.up)))
            for row in 0..<rows {
                for col in 0..<cols {
                    let x = clipped.minX + CGFloat(col) * cellW
                    let y = clipped.minY + CGFloat(row) * cellH
                    let w = min(cellW, clipped.maxX - x)
                    let h = min(cellH, clipped.maxY - y)
                    if w <= 0 || h <= 0 { continue }
                    queue.push(CGRect(x: x, y: y, width: w, height: h))
                }
            }
        }

        let touchTargetSlop: CGFloat = 2

        drain: while let cell = queue.pop(), budget.remaining > 0 {
            let centre = CGPoint(x: cell.midX, y: cell.midY)

            if covered.contains(where: { $0.insetBy(dx: -touchTargetSlop, dy: -touchTargetSlop).contains(centre) }) {
                perf?.recordOutcome("skip-covered")
                continue
            }

            budget.consume()

            let hit: [String: Any]?
            do {
                hit = try await probe(centre)
            } catch {
                hit = nil
            }

            guard let hit else {
                // Nil-refine is capped per phase. A sparse screen (few
                // children, many big empty gaps) used to cascade every
                // 80pt nil into 4, 16, 64 sub-cells and burn the whole
                // budget confirming empty space — LINE SDK Sample took
                // 1.8 s that way. Phase 1 caps looser (tiny AXGroup
                // containers may legitimately hide a single tight
                // element); phase 2 caps tighter because the parent
                // already has children and the blind zone is usually
                // either populated (real WebView) or really empty (pure
                // UIKit chrome).
                let cap = seedRegions == nil ? tuning.phase1NilRefineCap : tuning.phase2NilRefineCap
                if nilRefineCount < cap, min(cell.width, cell.height) > CGFloat(tuning.minCellSize) {
                    for quadrant in splitQuadrants(cell) { queue.push(quadrant) }
                    nilRefineCount += 1
                    perf?.recordOutcome("nil-refined")
                } else {
                    perf?.recordOutcome("nil-dropped")
                }
                continue
            }

            let hitFrameStr = (hit["AXFrame"] as? String) ?? ""
            if hitFrameStr == parentFrameStr {
                perf?.recordOutcome("filter-parent")
                continue
            }

            guard let hitRect = rect(of: hit) else {
                perf?.recordOutcome("filter-bad-frame")
                continue
            }

            if !rectContained(hitRect, in: region, slack: slack) {
                perf?.recordOutcome("filter-outside")
                continue
            }

            // Phase 2 dedup: a hit inside any existing direct-child frame is
            // already represented by a descendant of that child — reject it.
            if childFrames.contains(where: { rectContained(hitRect, in: $0, slack: slack) }) {
                perf?.recordOutcome("dedup-descendant")
                continue
            }

            // Nil key → zero/missing-frame hit: bypass identity dedup so
            // UIKit placeholder artifacts don't get swallowed. Geometric
            // filters above still apply.
            if let key = identityKey(for: hit) {
                if seen.contains(key) {
                    perf?.recordOutcome("dedup-seen")
                    continue
                }
                seen.insert(key)
            }
            var marked = hit
            marked["synthesized"] = true
            hits.append(marked)
            covered.append(hitRect)
            perf?.recordOutcome("new-hit")

            let clipped = hitRect.intersection(region)
            if !clipped.isNull {
                coveredArea += clipped.width * clipped.height
                if coveredArea >= coverageTarget { break drain }
            }

            // Opportunistic remainder subdivide: everything the hit did
            // not occupy becomes a candidate for further sampling so
            // thin neighbours (like the nav-bar row links) stay
            // reachable through the refinement chain.
            for remainder in subtract(hitRect, from: cell)
            where remainder.width * remainder.height > CGFloat(tuning.minRemainderArea) {
                queue.push(remainder)
            }
        }

        if !hits.isEmpty {
            let parentLabel = (parent["AXLabel"] as? String) ?? "<no label>"
            let phase = seedRegions == nil ? "phase1" : "phase2"
            logger.debug().log(
                "CollapsedChildrenRecovery: synthesized \(hits.count) children under '\(parentLabel)' (\(phase), remaining=\(budget.remaining))"
            )
        }
        return hits
    }

    // MARK: - Geometry helpers

    private static func rectContained(_ inner: CGRect, in outer: CGRect, slack: CGFloat) -> Bool {
        if inner.minX + slack < outer.minX { return false }
        if inner.maxX > outer.maxX + slack { return false }
        if inner.minY + slack < outer.minY { return false }
        if inner.maxY > outer.maxY + slack { return false }
        return true
    }

    private static func splitQuadrants(_ cell: CGRect) -> [CGRect] {
        let halfW = cell.width / 2
        let halfH = cell.height / 2
        return [
            CGRect(x: cell.minX,         y: cell.minY,         width: halfW, height: halfH),
            CGRect(x: cell.minX + halfW, y: cell.minY,         width: halfW, height: halfH),
            CGRect(x: cell.minX,         y: cell.minY + halfH, width: halfW, height: halfH),
            CGRect(x: cell.minX + halfW, y: cell.minY + halfH, width: halfW, height: halfH),
        ]
    }

    // Classic 4-strip rectangle subtraction: `cell` minus the portion of
    // `hit` that overlaps it. Strips are disjoint and their union equals
    // `cell \ (cell ∩ hit)`. Returns empty when `hit` fully covers `cell`
    // or doesn't overlap it at all.
    private static func subtract(_ hit: CGRect, from cell: CGRect) -> [CGRect] {
        let ix = cell.intersection(hit)
        if ix.isNull || ix.isEmpty { return [] }

        var strips: [CGRect] = []
        if ix.minY > cell.minY {
            strips.append(CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: ix.minY - cell.minY))
        }
        if ix.maxY < cell.maxY {
            strips.append(CGRect(x: cell.minX, y: ix.maxY, width: cell.width, height: cell.maxY - ix.maxY))
        }
        if ix.minX > cell.minX {
            strips.append(CGRect(x: cell.minX, y: ix.minY, width: ix.minX - cell.minX, height: ix.height))
        }
        if ix.maxX < cell.maxX {
            strips.append(CGRect(x: ix.maxX, y: ix.minY, width: cell.maxX - ix.maxX, height: ix.height))
        }
        return strips
    }

    /// Horizontal-strip decomposition of `region \ ⋃ covers`. Returns
    /// disjoint rectangles whose union is the uncovered area, with
    /// vertically-adjacent strips that share the same x-span merged into
    /// tall rectangles so the area / min-dimension filters treat a single
    /// logical gap as a single candidate zone.
    public static func computeBlindZones(in region: CGRect, coveredBy covers: [CGRect]) -> [CGRect] {
        guard region.width > 0, region.height > 0 else { return [] }

        let clipped: [CGRect] = covers.compactMap { r in
            let ix = r.intersection(region)
            return (ix.isNull || ix.isEmpty) ? nil : ix
        }
        if clipped.isEmpty { return [region] }

        var ys: Set<CGFloat> = [region.minY, region.maxY]
        for r in clipped {
            ys.insert(r.minY)
            ys.insert(r.maxY)
        }
        let sortedYs = ys.sorted()

        var zones: [CGRect] = []
        for i in 0..<(sortedYs.count - 1) {
            let yTop = sortedYs[i]
            let yBot = sortedYs[i + 1]
            let stripHeight = yBot - yTop
            if stripHeight <= 0 { continue }

            var intervals: [(x0: CGFloat, x1: CGFloat)] = []
            for r in clipped where r.minY < yBot && r.maxY > yTop {
                intervals.append((r.minX, r.maxX))
            }
            intervals.sort { $0.x0 < $1.x0 }

            var merged: [(x0: CGFloat, x1: CGFloat)] = []
            for iv in intervals {
                if !merged.isEmpty, merged[merged.count - 1].x1 >= iv.x0 {
                    merged[merged.count - 1].x1 = max(merged[merged.count - 1].x1, iv.x1)
                } else {
                    merged.append(iv)
                }
            }

            var x = region.minX
            for iv in merged {
                if iv.x0 > x {
                    zones.append(CGRect(x: x, y: yTop, width: iv.x0 - x, height: stripHeight))
                }
                x = max(x, iv.x1)
            }
            if x < region.maxX {
                zones.append(CGRect(x: x, y: yTop, width: region.maxX - x, height: stripHeight))
            }
        }

        // Merge vertically adjacent strips with identical x-span so a tall
        // blind zone stays a single rectangle after decomposition.
        zones.sort { lhs, rhs in
            if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
            return lhs.minY < rhs.minY
        }
        var mergedZones: [CGRect] = []
        let tol: CGFloat = 0.001
        for z in zones {
            if let last = mergedZones.last,
               abs(last.minX - z.minX) < tol,
               abs(last.width - z.width) < tol,
               abs(last.maxY - z.minY) < tol {
                mergedZones[mergedZones.count - 1] = CGRect(
                    x: last.minX,
                    y: last.minY,
                    width: last.width,
                    height: last.height + z.height
                )
            } else {
                mergedZones.append(z)
            }
        }
        return mergedZones
    }

    private static func frameTuple(of node: [String: Any]) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard let f = node["frame"] as? [String: Any] else { return nil }

        func readNumber(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let n = v as? NSNumber { return n.doubleValue }
            return nil
        }

        guard let x = readNumber(f["x"]),
              let y = readNumber(f["y"]),
              let width = readNumber(f["width"]),
              let height = readNumber(f["height"]) else {
            return nil
        }
        return (x, y, width, height)
    }

    private static func rect(of node: [String: Any]) -> CGRect? {
        guard let f = frameTuple(of: node) else { return nil }
        return CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
    }
}

// MARK: - Probe budget
//
// Shared mutable counter threaded through every probe call in a single
// `recover` invocation. Kept as a reference type so a tree walk in
// `async` context can drain the same budget across phase 1 and phase 2
// without inout gymnastics.
@MainActor
public final class ProbeBudget {
    private(set) var remaining: Int

    public init(_ budget: Int) { self.remaining = max(0, budget) }

    public func consume() {
        if remaining > 0 { remaining -= 1 }
    }
}

// MARK: - Seen identity set
//
// Traversal-scoped dedup for synthesized probe hits. Shared across every
// `runProbes` call in a single `recover` invocation so sibling AXGroup
// wrappers that each hit-test the same on-screen element collapse into one
// entry rather than duplicating it under every wrapper. Reference type so
// the shared state threads cleanly through the recursive async walk.
@MainActor
public final class SeenIdentitySet {
    private var keys: Set<String> = []

    public func insert(_ key: String) { keys.insert(key) }
    public func contains(_ key: String) -> Bool { keys.contains(key) }
}

// MARK: - Work queue
//
// Max-heap semantics by rectangle area. Naive sorted-array impl: cells are
// kept in ascending area order, and popping takes the last element. On ties
// the oldest insertion pops first — deterministic left-to-right, top-to-bottom
// iteration for the seed phase.
//
// The per-run cell count is bounded by the shared probe budget and the
// area threshold, typically well under 200, so a full priority queue is
// overkill for MVP.
private struct WorkQueue {
    private var items: [(rect: CGRect, area: CGFloat)] = []

    public mutating func push(_ rect: CGRect) {
        let area = rect.width * rect.height
        if area <= 0 { return }
        // Insert before the first item with area >= new area, keeping older
        // same-area items closer to the end of the array → FIFO on ties.
        let idx = items.firstIndex(where: { $0.area >= area }) ?? items.endIndex
        items.insert((rect, area), at: idx)
    }

    public mutating func pop() -> CGRect? {
        items.popLast()?.rect
    }
}