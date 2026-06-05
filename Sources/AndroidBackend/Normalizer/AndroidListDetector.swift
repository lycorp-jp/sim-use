// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Tier-1 list detector for Android. Walks the tree looking for nodes
/// whose `className` is a known collection container (RecyclerView /
/// ListView / GridView) or whose wire `collectionInfo` is populated.
/// Per S6 of the plan, Tier-1 clusters score `1.0` and rank first.
///
/// Tier-2 heuristic clustering is deferred to V3 (LINEAND-222541).
public enum AndroidListDetector {

    /// className whitelist for unconditional Tier-1 detection.
    /// **ViewPager/ViewPager2 are intentionally excluded** — they hold
    /// *pages*, not list cells, and treating them as lists pollutes
    /// scope numbering with one giant "list of one cell" entry that
    /// covers the entire screen. Pages are addressed via swipe verbs.
    public static let collectionClasses: Set<String> = [
        "androidx.recyclerview.widget.RecyclerView",
        "android.widget.ListView",
        "android.widget.GridView",
    ]

    public struct Cluster {
        public let frame: Outline.Frame
        public let containerRole: String
        public let containerLabel: String?
        public let cellFrames: [Outline.Frame]
        public let cellHeight: Int
        public let score: Double
    }

    public static func detect(root: ElementNode) -> [Cluster] {
        let screen = root.boundsInScreen.toFrame()
        var raw: [Cluster] = []
        walk(node: root, into: &raw)
        let filtered = raw.filter { isUsable($0, screen: screen) }
        let deduped = dropNestedShadows(filtered)
        return deduped.sorted { a, b in
            let aArea = a.frame.width * a.frame.height
            let bArea = b.frame.width * b.frame.height
            return aArea > bArea
        }
    }

    private static func walk(node: ElementNode, into clusters: inout [Cluster]) {
        if isCollection(node) {
            let frame = node.boundsInScreen.toFrame()
            let containerRole = AndroidClassifier.role(for: node)
            let containerLabel: String? = {
                let raw = node.contentDescription.isEmpty ? node.text : node.contentDescription
                return raw.isEmpty ? nil : raw
            }()
            // Cells must be (a) visible per the platform's
            // `isVisibleToUser` signal, (b) geometrically non-empty, and
            // (c) overlap the container's own frame. RecyclerView keeps
            // recycled-but-attached children in the tree with stale
            // bounds (often negative-y after a scroll); without these
            // filters they pad `cellFrames.count` past the visible row
            // count and skew `#N@M` aliasing.
            let visibleChildren = node.children.filter { child in
                guard child.visibleToUser else { return false }
                let f = child.boundsInScreen
                guard f.width > 0, f.height > 0 else { return false }
                return Self.framesOverlap(f.toFrame(), frame)
            }
            let cellFrames = visibleChildren.map { $0.boundsInScreen.toFrame() }
            let cellHeight = medianHeight(cellFrames)
            // Tier-1 score per S6.
            clusters.append(Cluster(
                frame: frame,
                containerRole: containerRole,
                containerLabel: containerLabel,
                cellFrames: cellFrames,
                cellHeight: cellHeight,
                score: 1.0
            ))
        }
        for child in node.children {
            walk(node: child, into: &clusters)
        }
    }

    private static func isCollection(_ node: ElementNode) -> Bool {
        if collectionClasses.contains(node.className) { return true }
        if node.collectionInfo != nil { return true }
        return false
    }

    /// A cluster is "usable" — worth showing to the agent — only if:
    ///   * it has ≥ 2 visible cells (a one-cell "list" is just a row),
    ///   * its bbox has positive area and overlaps the screen rect,
    ///   * its cells aren't comically tall (a cell taller than half
    ///     the screen is almost always a wrapper masquerading as a
    ///     cell — `View(rowCount=1) → child=full-page`).
    private static func isUsable(_ c: Cluster, screen: Outline.Frame) -> Bool {
        guard c.cellFrames.count >= 2 else { return false }
        guard c.frame.width > 0, c.frame.height > 0 else { return false }
        // Screen overlap check (avoids off-screen ViewPager neighbour
        // pages at x=-1080 or x=+1080 from polluting the cluster list).
        if screen.width > 0, screen.height > 0 {
            if c.frame.x + c.frame.width <= 0 { return false }
            if c.frame.y + c.frame.height <= 0 { return false }
            if c.frame.x >= screen.x + screen.width { return false }
            if c.frame.y >= screen.y + screen.height { return false }
        }
        if c.cellHeight > 0, c.cellHeight > screen.height / 2 { return false }
        return true
    }

    /// When two clusters nest (A fully contains B) and A's cells are
    /// effectively "B plus wrappers", drop A. Concretely, the
    /// chat-list path in a LINE-like UI is several wrapper Views all
    /// flagged with `collectionInfo`; only the innermost one has the
    /// real cell count. Keep the one with the **most** cells, breaking
    /// ties by smaller area.
    private static func dropNestedShadows(_ clusters: [Cluster]) -> [Cluster] {
        // Walk by index so the "skip myself" test is identity-based
        // rather than the brittle `frame == frame && cellFrames.count
        // == cellFrames.count` proxy the previous implementation
        // used. The proxy happened to work for the cases we ship
        // today, but a future cluster that legitimately shares a
        // frame with a sibling (e.g. two adjacent RecyclerViews
        // identically positioned by a CoordinatorLayout snap) would
        // have silently exempted itself.
        var result: [Cluster] = []
        for (i, c) in clusters.enumerated() {
            var redundant = false
            for (j, o) in clusters.enumerated() where i != j {
                // Drop `c` if any sibling `o` fully contains it AND
                // has at least as many cells (the outer is the "real"
                // list and `c` is one of its cells masquerading as a
                // sub-list).
                if frameContains(c.frame, o.frame), o.cellFrames.count > c.cellFrames.count {
                    redundant = true; break
                }
                // Drop `c` if any sibling `o` is fully contained in
                // `c` AND has at least as many cells AND has a
                // strictly smaller frame (so it's truly inner, not a
                // tie). Tie-frames with identical cell counts are
                // semantically equivalent and both survive.
                if frameContains(o.frame, c.frame), o.cellFrames.count >= c.cellFrames.count, o.frame != c.frame {
                    redundant = true; break
                }
            }
            if !redundant { result.append(c) }
        }
        return result
    }

    private static func framesOverlap(_ a: Outline.Frame, _ b: Outline.Frame) -> Bool {
        let ax2 = a.x + a.width
        let ay2 = a.y + a.height
        let bx2 = b.x + b.width
        let by2 = b.y + b.height
        return a.x < bx2 && ax2 > b.x && a.y < by2 && ay2 > b.y
    }

    private static func frameContains(_ outer: Outline.Frame, _ inner: Outline.Frame) -> Bool {
        outer.x <= inner.x
            && outer.y <= inner.y
            && outer.x + outer.width >= inner.x + inner.width
            && outer.y + outer.height >= inner.y + inner.height
    }

    private static func medianHeight(_ frames: [Outline.Frame]) -> Int {
        guard !frames.isEmpty else { return 0 }
        let heights = frames.map { $0.height }.sorted()
        let n = heights.count
        if n.isMultiple(of: 2) {
            // Average the two middle values for even-count lists.
            // Previously this returned `heights[n/2]`, which is the
            // *upper* of the two middles, and skewed `cellHeight` for
            // 2-cell lists with disparate row heights (the most
            // common shape of a paginated chat list).
            return (heights[n / 2 - 1] + heights[n / 2]) / 2
        }
        return heights[n / 2]
    }
}