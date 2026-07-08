// SPDX-License-Identifier: Apache-2.0
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
    /// with its advisory attached.
    public struct FetchResult {
        public let data: Data
        public let calibration: OrientationCalibration?
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
            let future = target.accessibilityElement(at: point, nestedFormat: false)
            let raw: AnyObject = try await FutureBridge.value(future)
            let durationMs = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
            perf.recordProbe(durationMs: durationMs, phase: "objectAtPoint")
            return raw as? [String: Any]
        }

        if let point {
            return try await pointQuery(
                target: target,
                point: point,
                native: native,
                probe: probe,
                logger: logger,
                perf: perf
            )
        }

        let future = target.accessibilityElements(withNestedFormat: true)
        let info: AnyObject = try await FutureBridge.value(future)
        perf.stage("tree fetch XPC")

        let calibration = await calibrate(info: info, native: native, probe: probe, logger: logger)
        perf.stage("calibrate")

        // AX frames are UI-space while the hit-test consumes framebuffer
        // points (issue #34) — cross the boundary here so the quadtree's
        // UI-space bookkeeping stays untouched. Identity keeps the exact
        // pre-fix closure.
        let recoveryProbe: CollapsedChildrenRecovery.PointProbe = calibration.isIdentity
            ? probe
            : { p in try await probe(calibration.hidCGPoint(p)) }

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
        return FetchResult(data: data, calibration: calibration)
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
    /// uses. The hit-test XPC consumes framebuffer points, so a rotated
    /// device needs the query transformed. The first probe doubles as
    /// calibration evidence: its returned frame tells us which orientations
    /// could map this point into it. Portrait wins ties (a fat frame
    /// containing several projections proves nothing, and portrait is the
    /// overwhelmingly common case); only an unambiguous non-portrait match
    /// or a full tree calibration triggers the transformed re-query.
    private static func pointQuery(
        target: FBSimulator,
        point: AccessibilityPoint,
        native: NativePortraitSize?,
        probe: @escaping CollapsedChildrenRecovery.PointProbe,
        logger: SimUseLogger,
        perf: PerfLog
    ) async throws -> FetchResult {
        func nestedQuery(_ p: CGPoint) async throws -> AnyObject {
            let future = target.accessibilityElement(at: p, nestedFormat: true)
            return try await FutureBridge.value(future)
        }

        guard let native else {
            // No screen info — keep the legacy raw-space behavior.
            let info = try await nestedQuery(point.cgPoint)
            perf.stage("point XPC")
            let data = try serializeAccessibilityInfo(info)
            perf.finish()
            return FetchResult(data: data, calibration: .identity())
        }

        var orientation: DisplayOrientation? = nil
        var identityResult: AnyObject? = nil
        var calibration: OrientationCalibration? = nil

        if point.x < native.width, point.y < native.height {
            if let raw = try? await nestedQuery(point.cgPoint) {
                perf.stage("point XPC")
                identityResult = raw
                if let dict = raw as? [String: Any],
                   let frame = OrientationCalibrator.frameRect(of: dict) {
                    let expanded = frame.insetBy(
                        dx: -OrientationCalibrator.containmentSlack,
                        dy: -OrientationCalibrator.containmentSlack
                    )
                    let contained = DisplayOrientation.allCases.filter {
                        expanded.contains($0.framebufferToUI(point.cgPoint, native: native))
                    }
                    if contained.contains(.portrait) {
                        orientation = .portrait
                    } else if contained.count == 1 {
                        orientation = contained[0]
                    }
                }
            }
        }
        // A UI point outside the native portrait bounds can only exist in
        // a landscape UI — the identity probe was skipped above and the
        // tree calibration below settles which landscape.

        if orientation == nil {
            let future = target.accessibilityElements(withNestedFormat: true)
            if let info: AnyObject = try? await FutureBridge.value(future) {
                perf.stage("tree fetch XPC (point calibration)")
                let treeCalibration = await calibrate(info: info, native: native, probe: probe, logger: logger)
                calibration = treeCalibration
                orientation = treeCalibration.orientation
            }
        }

        let resolved = orientation ?? .portrait
        let finalCalibration = calibration ?? OrientationCalibration(
            orientation: resolved, native: native, probesUsed: 1, advisory: nil
        )

        let info: AnyObject
        if resolved == .portrait, let identityResult {
            info = identityResult
        } else {
            info = try await nestedQuery(finalCalibration.hidCGPoint(point.cgPoint))
            perf.stage("point XPC (transformed)")
        }
        let data = try serializeAccessibilityInfo(info)
        perf.stage("serialize")
        perf.finish()
        return FetchResult(data: data, calibration: finalCalibration)
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

    private static func rawRoots(of info: AnyObject) -> [[String: Any]] {
        if let array = info as? [[String: Any]] { return array }
        if let dict = info as? [String: Any] { return [dict] }
        return []
    }

    /// Raw-payload mirror of `AXDisplayFrame.frame(in:)`: the largest
    /// positive-area Application-typed root, falling back to the largest
    /// root of any type.
    private static func rawDisplayFrame(in roots: [[String: Any]]) -> CGRect? {
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