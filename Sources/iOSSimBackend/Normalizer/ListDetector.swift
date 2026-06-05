// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Detects list-like clusters in an accessibility tree.
///
/// Two clustering strategies run in parallel on every container:
///
/// 1. **Height-pass** — the original spike algorithm. Group same-rounded-
///    height children, score on Δy consistency. Strong signal for chats,
///    share pickers, news feeds, anything where every row is the same
///    shape.
///
/// 2. **Row-shaped pass** — bucket children by rounded x and require
///    similar widths near the container's full width. Cells inside a
///    bucket are sorted by y, dropped if they overlap a previous one,
///    and clustered if their inter-row gaps are roughly consistent.
///    Catches variable-height settings menus where heights are
///    `[87, 48, 87, 87, 102, 48, 48]` but every row is full-width and
///    tightly stacked.
///
/// Both passes feed candidates into a global score-sort and a greedy
/// non-overlap pick. A single visual element never lands in two
/// emitted clusters.
///
/// Gates filter false positives (banner-internal label pairs, scattered
/// same-height CTAs, single section headers etc.) — see the constants
/// below for thresholds and rationale.
public enum ListDetector {
    /// One detected cell. `frame` is integer-rounded to match the
    /// outline's frame rounding so callers can match a cell back to its
    /// `Outline.Entry` by `(frame, role)`.
    public struct DetectedCell: Equatable, Hashable {
        public let frame: Outline.Frame
        public let role: String
    }

    /// One detected list cluster.
    /// `cells` is in `(y, x)` reading order.
    /// `bbox` unions every cell frame, integer-rounded.
    /// `score` is the raw detector score; consumers should treat it as
    /// informational only — only relative ordering between clusters is
    /// contractual.
    public struct Cluster {
        public let cells: [DetectedCell]
        public let cellHeight: Int
        public let containerRole: String
        public let containerLabel: String?
        public let bbox: Outline.Frame
        public let score: Double
    }

    // MARK: - Tunable thresholds

    /// Minimum cells per cluster. Deliberately kept at 2 so a
    /// legitimately-short list (2 settings rows, 2 chat results) still
    /// gets `#N` aliases. False-positive 2-cell pairs are caught by the
    /// other gates below instead of by raising this floor.
    public static let minCellCount = 2

    /// A cluster's mean cell width must be at least this. Catches the
    /// "two paired banner-control icons stacked at 17pt wide" false
    /// positive without affecting any real list (rows are rarely below
    /// 80pt).
    public static let minMeanWidth: Double = 80

    /// Cells whose widths span more than this ratio aren't a list —
    /// they're disparate elements that happen to share a height (e.g. a
    /// long status label + a short "Skip" CTA at the same y-band).
    public static let maxWidthRatio: Double = 3.0

    /// For 3+ cell clusters the fraction of consecutive-gap consistency
    /// must reach this. 2/3 keeps the spike's news-feed (consistency
    /// 0.75 with one ad outlier) and drops "3 same-h rows with
    /// intervening rows" (consistency 0.5).
    public static let minConsistency = 2.0 / 3.0

    /// `medianGap ≤ K × cellHeight`. Rules out clusters where same-shape
    /// elements are scattered far apart vertically — the "two unrelated
    /// CTAs share a height across 200pt of dead space" pattern.
    public static let densityFactor = 3.5

    /// Backstop for the density gate when cells are very tall:
    /// `medianGap ≤ this × screenHeight` (skipped when screen height is
    /// unknown).
    public static let absoluteGapFactor = 0.25

    /// Cells taller than this fraction of screen height are typically
    /// containers, not list rows. Filters out the "list of full-page
    /// sections" false positive that emerges when a screen has 2 large
    /// stacked Groups at the same x.
    public static let maxCellHeightFraction = 0.25

    /// Row-shaped pass: candidates must occupy at least this fraction of
    /// their container's width to qualify as a row.
    public static let rowShapedWidthFraction: Double = 0.6

    /// Tighter width-ratio gate for the row-shaped pass. Variable-height
    /// rows still tend to share widths very tightly within a single list.
    public static let rowShapedWidthRatio: Double = 1.5

    /// Roles excluded from the row-shaped pass — section headings are
    /// commonly full-width but conceptually outside any list. Keep the
    /// height-pass case unaffected (it never grouped headings with
    /// non-headings anyway because heights differ).
    public static let rowShapedExcludedRoles: Set<String> = ["Heading"]

    /// Role-priority table for the in-container frame dedupe. iOS
    /// commonly exposes a row both as an actionable Button (the tap
    /// target) and as a StaticText (a composite VoiceOver label) at
    /// identical frames; the Button wins. Pure text rows with no
    /// actionable sibling are kept as-is. Roles not listed get
    /// priority 0.
    private static let rolePriority: [String: Int] = [
        "Button": 10,
        "Cell": 10,
        "RadioButton": 10,
        "CheckBox": 10,
        "Switch": 10,
        "Link": 10,
        "MenuItem": 10,
        "PopUpButton": 10,
        "SegmentedControl": 10,
        "Tab": 10,
        "TabBarButton": 10,
        "TextField": 9,
        "SecureTextField": 9,
        "StaticText": 5,
        "Heading": 4,
        "Image": 3,
        "Group": 2,
        "GenericElement": 1,
    ]

    // MARK: - Entry point

    /// `screenHeight` enables the absolute-gap and max-cell-height
    /// gates; pass 0 to skip them (subtree / `--point` mode).
    /// `minScore` filters out very-low-confidence candidates; default 0
    /// keeps every cluster that passes the structural gates.
    public static func detect(tree: [AccessibilityElement], screenHeight: Int = 0, minScore: Double = 0) -> [Cluster] {
        var candidates: [Cluster] = []
        for root in tree {
            walk(element: root, screenHeight: screenHeight, into: &candidates)
        }

        let filtered = candidates.filter { $0.score > minScore }
        let ranked = filtered.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            // Tiebreaker: more cells first, then earlier-appearing
            // (smaller bbox.y) first. Determinism safety net for inputs
            // that score identically across passes.
            if lhs.cells.count != rhs.cells.count {
                return lhs.cells.count > rhs.cells.count
            }
            return lhs.bbox.y < rhs.bbox.y
        }

        // Greedy: dominant first. Skip a candidate when either
        // - it shares a cell frame with an already-picked cluster
        //   (frame-overlap dedup), or
        // - a majority of its cells are geometrically *nested inside*
        //   already-picked cells (nestedness dedup). The second rule
        //   filters the iOS settings pattern where every row contains
        //   an inset description GenericElement at x=16 width=370 —
        //   those descriptions form their own row-shaped cluster but
        //   are visually inside their parent row, not a real list.
        var picked: [Cluster] = []
        var usedFrames: Set<Outline.Frame> = []
        var pickedCellFrames: [Outline.Frame] = []
        for cluster in ranked {
            let cellFrames = cluster.cells.map(\.frame)
            let cellFrameSet = Set(cellFrames)
            if !cellFrameSet.isDisjoint(with: usedFrames) {
                continue
            }
            let nestedCount = cellFrames.filter { isNested($0, inside: pickedCellFrames) }.count
            if cellFrames.count > 0, nestedCount * 2 > cellFrames.count {
                continue
            }
            picked.append(cluster)
            usedFrames.formUnion(cellFrameSet)
            pickedCellFrames.append(contentsOf: cellFrames)
        }
        return picked
    }

    /// True iff `candidate`'s rect is entirely inside any of `outers`.
    private static func isNested(_ candidate: Outline.Frame, inside outers: [Outline.Frame]) -> Bool {
        for outer in outers {
            if candidate.x >= outer.x,
               candidate.y >= outer.y,
               candidate.x + candidate.width <= outer.x + outer.width,
               candidate.y + candidate.height <= outer.y + outer.height {
                return true
            }
        }
        return false
    }

    // MARK: - Tree walk

    private static func walk(element: AccessibilityElement, screenHeight: Int, into candidates: inout [Cluster]) {
        let kids = element.children ?? []
        if kids.count >= minCellCount {
            collectHeightClusters(in: element, kids: kids, screenHeight: screenHeight, into: &candidates)
            collectRowShapedClusters(in: element, kids: kids, screenHeight: screenHeight, into: &candidates)
        }
        for child in kids {
            walk(element: child, screenHeight: screenHeight, into: &candidates)
        }
    }

    // MARK: - Height-pass (same-height clustering, original spike algorithm)

    private static func collectHeightClusters(
        in container: AccessibilityElement,
        kids: [AccessibilityElement],
        screenHeight: Int,
        into candidates: inout [Cluster]
    ) {
        let deduped = dedupeByFrame(kids)
        guard deduped.count >= minCellCount else { return }

        var byHeight: [Int: [AccessibilityElement]] = [:]
        for kid in deduped {
            guard let frame = kid.frame, frame.width > 0, frame.height > 0 else { continue }
            let h = Int(frame.height.rounded())
            byHeight[h, default: []].append(kid)
        }

        for (height, members) in byHeight where members.count >= minCellCount {
            if let cluster = makeHeightCluster(in: container, members: members, cellHeight: height, screenHeight: screenHeight) {
                candidates.append(cluster)
            }
        }
    }

    private static func makeHeightCluster(
        in container: AccessibilityElement,
        members: [AccessibilityElement],
        cellHeight: Int,
        screenHeight: Int
    ) -> Cluster? {
        let sorted = members.sorted { lhs, rhs in
            (lhs.frame?.y ?? 0) < (rhs.frame?.y ?? 0)
        }
        let ys = sorted.compactMap { $0.frame?.y }
        guard ys.count == sorted.count, ys.count >= 2 else { return nil }

        var gaps: [Double] = []
        gaps.reserveCapacity(ys.count - 1)
        for i in 0..<(ys.count - 1) {
            gaps.append(ys[i + 1] - ys[i])
        }
        guard !gaps.isEmpty else { return nil }
        let medianGap = gaps.sorted()[gaps.count / 2]
        guard medianGap > 0 else { return nil }

        // Height-pass consistency: ±40% of median (matches the original
        // spike). Tighter than the row-pass tolerance because same-height
        // lists are usually uniformly spaced.
        let tolerance = medianGap * 0.4
        let consistent = gaps.filter { abs($0 - medianGap) <= tolerance }.count
        let consistency = Double(consistent) / Double(gaps.count)

        let widths = sorted.compactMap { $0.frame?.width }
        let meanWidth = widths.isEmpty ? 0 : widths.reduce(0, +) / Double(widths.count)
        let widthRatio = computeWidthRatio(widths)

        guard passesGates(
            cellCount: sorted.count,
            meanWidth: meanWidth,
            widthRatio: widthRatio,
            medianGap: medianGap,
            medianHeight: Double(cellHeight),
            maxCellHeight: Double(cellHeight),
            consistency: consistency,
            screenHeight: screenHeight
        ) else { return nil }

        let distinctRoles = Set(sorted.map { $0.type ?? "" }).count
        let score = computeScore(
            cellCount: sorted.count,
            consistency: consistency,
            distinctRoles: distinctRoles,
            meanWidth: meanWidth
        )

        let cells = sorted.compactMap { detectedCell(for: $0) }
        guard cells.count == sorted.count else { return nil }
        return Cluster(
            cells: cells,
            cellHeight: cellHeight,
            containerRole: container.type ?? "Element",
            containerLabel: containerNormalizedLabel(container),
            bbox: boundingBox(cells),
            score: score
        )
    }

    // MARK: - Row-shaped pass (variable-height list support)

    private static func collectRowShapedClusters(
        in container: AccessibilityElement,
        kids: [AccessibilityElement],
        screenHeight: Int,
        into candidates: inout [Cluster]
    ) {
        guard let containerFrame = container.frame, containerFrame.width > 0 else { return }
        let containerWidth = containerFrame.width
        let widthThreshold = containerWidth * rowShapedWidthFraction

        let deduped = dedupeByFrame(kids)
        guard deduped.count >= minCellCount else { return }

        // Bucket by rounded x. Children within `widthFraction` of the
        // container width AND not in `excludedRoles` are eligible.
        var byX: [Int: [AccessibilityElement]] = [:]
        for kid in deduped {
            guard let frame = kid.frame, frame.width > 0, frame.height > 0 else { continue }
            guard frame.width >= widthThreshold else { continue }
            if rowShapedExcludedRoles.contains(kid.type ?? "") { continue }
            let x = Int(frame.x.rounded())
            byX[x, default: []].append(kid)
        }

        for (_, members) in byX where members.count >= minCellCount {
            if let cluster = makeRowShapedCluster(in: container, members: members, screenHeight: screenHeight) {
                candidates.append(cluster)
            }
        }
    }

    private static func makeRowShapedCluster(
        in container: AccessibilityElement,
        members: [AccessibilityElement],
        screenHeight: Int
    ) -> Cluster? {
        let initialWidths = members.compactMap { $0.frame?.width }
        let widthRatio = computeWidthRatio(initialWidths)
        guard widthRatio <= rowShapedWidthRatio else { return nil }

        // Sort by y, drop overlapping. We only emit non-overlapping
        // vertical stacks because a "list" implies a sequence the user
        // can scan top-to-bottom without z-ordering.
        let sortedByY = members.sorted { lhs, rhs in
            (lhs.frame?.y ?? 0) < (rhs.frame?.y ?? 0)
        }
        var stacked: [AccessibilityElement] = []
        var lastBottom: Double = -.greatestFiniteMagnitude
        for cand in sortedByY {
            guard let frame = cand.frame else { continue }
            if frame.y >= lastBottom {
                stacked.append(cand)
                lastBottom = frame.y + frame.height
            }
        }
        guard stacked.count >= minCellCount else { return nil }

        // Inter-row gaps: top of next minus bottom of previous. Negative
        // values are clamped to 0 (defensive — should not happen after
        // the overlap drop above).
        var interGaps: [Double] = []
        interGaps.reserveCapacity(stacked.count - 1)
        for i in 0..<(stacked.count - 1) {
            let prevBottom = (stacked[i].frame?.y ?? 0) + (stacked[i].frame?.height ?? 0)
            let nextTop = stacked[i + 1].frame?.y ?? 0
            interGaps.append(max(0, nextTop - prevBottom))
        }

        // Row-pass consistency: a gap counts as consistent if it's
        // either tiny (≤ 4pt — "touching" rows) OR within ±50% of the
        // median. The dual-band check accommodates settings menus where
        // some rows touch and others have a small inter-section
        // breathing space.
        let medianGap = interGaps.isEmpty ? 0 : interGaps.sorted()[interGaps.count / 2]
        let touchingThreshold: Double = 4
        let tolerance = medianGap * 0.5
        let consistentCount = interGaps.filter { gap in
            gap <= touchingThreshold || abs(gap - medianGap) <= tolerance
        }.count
        let consistency = interGaps.isEmpty ? 1.0 : Double(consistentCount) / Double(interGaps.count)

        let heights = stacked.compactMap { $0.frame?.height }.sorted()
        guard !heights.isEmpty else { return nil }
        let medianHeight = heights[heights.count / 2]
        let maxCellHeight = heights.last ?? 0

        let widths = stacked.compactMap { $0.frame?.width }
        let meanWidth = widths.isEmpty ? 0 : widths.reduce(0, +) / Double(widths.count)
        let stackedWidthRatio = computeWidthRatio(widths)

        guard passesGates(
            cellCount: stacked.count,
            meanWidth: meanWidth,
            widthRatio: stackedWidthRatio,
            medianGap: medianGap,
            medianHeight: medianHeight,
            maxCellHeight: maxCellHeight,
            consistency: consistency,
            screenHeight: screenHeight
        ) else { return nil }

        let distinctRoles = Set(stacked.map { $0.type ?? "" }).count
        let score = computeScore(
            cellCount: stacked.count,
            consistency: consistency,
            distinctRoles: distinctRoles,
            meanWidth: meanWidth
        )

        let cells = stacked.compactMap { detectedCell(for: $0) }
        guard cells.count == stacked.count else { return nil }
        return Cluster(
            cells: cells,
            cellHeight: Int(medianHeight.rounded()),
            containerRole: container.type ?? "Element",
            containerLabel: containerNormalizedLabel(container),
            bbox: boundingBox(cells),
            score: score
        )
    }

    // MARK: - Shared gate / score / dedupe

    private static func passesGates(
        cellCount: Int,
        meanWidth: Double,
        widthRatio: Double,
        medianGap: Double,
        medianHeight: Double,
        maxCellHeight: Double,
        consistency: Double,
        screenHeight: Int
    ) -> Bool {
        guard cellCount >= minCellCount else { return false }
        guard meanWidth >= minMeanWidth else { return false }
        guard widthRatio <= maxWidthRatio else { return false }
        // Consistency is meaningful only with multiple gaps (≥ 3 cells).
        // With 2 cells the single gap is trivially "100% consistent",
        // so applying the gate would be a no-op anyway.
        if cellCount >= 3 {
            guard consistency >= minConsistency else { return false }
        }
        // Density gate is meaningless when medianHeight is 0.
        if medianHeight > 0 {
            guard medianGap <= densityFactor * medianHeight else { return false }
        }
        if screenHeight > 0 {
            guard medianGap <= Double(screenHeight) * absoluteGapFactor else { return false }
            guard maxCellHeight <= Double(screenHeight) * maxCellHeightFraction else { return false }
        }
        return true
    }

    private static func computeScore(
        cellCount: Int,
        consistency: Double,
        distinctRoles: Int,
        meanWidth: Double
    ) -> Double {
        let roleBonus: Double
        switch distinctRoles {
        case 1: roleBonus = 1.5
        case 2: roleBonus = 1.2
        default: roleBonus = 1.0
        }
        let widthBonus: Double
        if meanWidth > 200 {
            widthBonus = 1.3
        } else if meanWidth > 80 {
            widthBonus = 1.1
        } else {
            widthBonus = 1.0
        }
        return Double(cellCount) * consistency * roleBonus * widthBonus
    }

    private static func computeWidthRatio(_ widths: [Double]) -> Double {
        guard let maxW = widths.max(), let minW = widths.min(), minW > 0 else {
            return .infinity
        }
        return maxW / minW
    }

    /// Collapse multiple a11y nodes that occupy the same rounded rect
    /// into a single logical cell, preferring the most actionable role.
    /// The integer-rounded rect is the dedupe key — sub-point jitter
    /// from layout calculations is irrelevant.
    private static func dedupeByFrame(_ kids: [AccessibilityElement]) -> [AccessibilityElement] {
        struct Key: Hashable {
            public let frame: Outline.Frame
        }
        var best: [Key: AccessibilityElement] = [:]
        for kid in kids {
            guard let frame = kid.frame else { continue }
            let key = Key(frame: Outline.Frame(
                x: Int(frame.x.rounded()),
                y: Int(frame.y.rounded()),
                width: Int(frame.width.rounded()),
                height: Int(frame.height.rounded())
            ))
            if let prior = best[key] {
                if priority(of: kid) > priority(of: prior) {
                    best[key] = kid
                }
            } else {
                best[key] = kid
            }
        }
        return Array(best.values)
    }

    private static func priority(of element: AccessibilityElement) -> Int {
        rolePriority[element.type ?? ""] ?? 0
    }

    private static func containerNormalizedLabel(_ element: AccessibilityElement) -> String? {
        guard let label = element.normalizedLabel, !label.isEmpty else { return nil }
        return label
    }

    private static func detectedCell(for element: AccessibilityElement) -> DetectedCell? {
        guard let frame = element.frame else { return nil }
        let rounded = Outline.Frame(
            x: Int(frame.x.rounded()),
            y: Int(frame.y.rounded()),
            width: Int(frame.width.rounded()),
            height: Int(frame.height.rounded())
        )
        return DetectedCell(frame: rounded, role: element.type ?? "Element")
    }

    private static func boundingBox(_ cells: [DetectedCell]) -> Outline.Frame {
        guard let first = cells.first else {
            return Outline.Frame(x: 0, y: 0, width: 0, height: 0)
        }
        var minX = first.frame.x
        var minY = first.frame.y
        var maxX = first.frame.x + first.frame.width
        var maxY = first.frame.y + first.frame.height
        for cell in cells.dropFirst() {
            minX = min(minX, cell.frame.x)
            minY = min(minY, cell.frame.y)
            maxX = max(maxX, cell.frame.x + cell.frame.width)
            maxY = max(maxY, cell.frame.y + cell.frame.height)
        }
        return Outline.Frame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}