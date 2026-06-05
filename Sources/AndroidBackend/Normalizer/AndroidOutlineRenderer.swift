// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Renders an Android `ElementNode` tree into the cross-platform `Outline`
/// shape. Structural twin of iOS `OutlineFormatter` — same headers,
/// `@N`/`#N` aliases, state-tag conventions. Android-specific fields
/// (`resource_id`, `hint`, `package`) flow through `Outline.Entry`
/// without changing the text-line width.
public enum AndroidOutlineRenderer {

    /// Marker the bridge stamps on the synthetic wrapper that holds the
    /// active window's root **plus** any same-task secondary window
    /// roots (PopupWindow / anchored Dialog / Spinner dropdown / etc.).
    /// Wire spec mirror — bridge side at
    /// `ActionRouter.MULTI_WINDOW_MARKER`. Identifiable by both
    /// `className` *and* `resourceId` (no real Android class or
    /// resource id can collide because neither namespace allows this
    /// shape).
    public static let multiWindowMarker = "__simuse:multi_window__"

    /// y-band depth for Top/Bottom region classification, in **pixels**.
    /// iOS uses 120 pt — on a 2400 px Android display that translates to
    /// ~280 px once we account for system status bar (~132 px) + a
    /// typical toolbar (~140 px). Below 280 px we miss real headers
    /// like `user_profile_header_binding` at y=132 from getting tagged
    /// as Top.
    public static let yBandInset: Int = 280

    public struct RendererOptions: Sendable {
        public var filterOffscreen: Bool
        public init(filterOffscreen: Bool = true) {
            self.filterOffscreen = filterOffscreen
        }
        public static let `default` = RendererOptions()
    }

    struct Working {
        let node: ElementNode
        let frame: Outline.Frame
        let depth: Int
        let declaredRegion: Outline.Region?
        let role: String
        let label: String
        /// Effective `uniqueId` for the rendered entry. Defaults to
        /// `node.uniqueId`; `foldContainerText` may override it with
        /// a non-empty `uniqueId` from a non-interactable inner
        /// child whose label/id flow into the folded entry. Without
        /// the override, folding a wrapper-with-no-uniqueId over a
        /// child that DOES carry one drops the child's id — and
        /// `tap --id <inner-uniqueId>` later returns `.noMatch`
        /// even though the inner element is still in the live AX
        /// tree.
        let uniqueId: String?
    }

    public static func render(
        root: ElementNode,
        display: DisplayMetrics? = nil,
        options: RendererOptions = .default
    ) -> Outline {
        // Multi-window collapse: when the bridge wrapped multiple
        // windows under `multiWindowMarker`, the active window
        // (children[0]) is almost always behind a modal popup —
        // tapping any of its items would dismiss the popup rather
        // than fire the row. iOS handles this transparently:
        // `UIContextMenu` marks the surrounding UI as non-accessible
        // so describe-ui only sees the menu. Mirror that here by
        // walking *only* the secondary window roots; the active root
        // is kept as the app-label source so the "App: <name>" header
        // still reflects the foreground app.
        //
        // When the wrapper has fewer than 2 children (defensive: a
        // bridge that emitted the wrapper for a single window) we
        // fall through and walk whatever children exist, so no
        // information is dropped on the floor.
        let topLevelNodes: [ElementNode]
        let appLabelSource: ElementNode
        if root.className == multiWindowMarker {
            if root.children.count >= 2 {
                appLabelSource = root.children[0]
                topLevelNodes = Array(root.children.dropFirst())
            } else {
                appLabelSource = root.children.first ?? root
                topLevelNodes = root.children
            }
        } else {
            appLabelSource = root
            topLevelNodes = root.children
        }

        // `screen` defines the coordinate space for the offscreen filter,
        // the yBand region split, and the header line. Prefer the bridge-
        // reported device display (origin 0,0, full device pixels) — for
        // popups / dialogs the active window's `boundsInScreen` is a
        // small sub-rect of the device, which silently mis-zones every
        // popup item as "Top" or "Bottom" relative to the popup itself.
        let screen: Outline.Frame
        if let display, display.width > 0, display.height > 0 {
            screen = Outline.Frame(x: 0, y: 0, width: display.width, height: display.height)
        } else {
            screen = root.boundsInScreen.toFrame()
        }
        let appLabel = appLabel(for: appLabelSource)

        var collected: [Working] = []
        let rootChildRepeats = repeatingShortIdCount(among: topLevelNodes)
        for child in topLevelNodes {
            let repeats = rootChildRepeats[child.resourceIdShortName, default: 0] >= 2
            walk(node: child, depth: 1, declared: nil, screen: screen, options: options,
                 siblingIdRepeats: repeats, into: &collected)
        }

        let folded = foldContainerText(collected)
        let cleaned = dropRedundantOuter(folded)
        // Sort by `frame.y` (top edge), not center-y. The center-y
        // sort tangled list cells into their own children: a chat row
        // at (y=273, h=179, center=362) sorted *after* its TextView
        // children at (y=317, h=34..47, center=338..340). Using the
        // top edge makes the container come first naturally, then its
        // children in their own top-edge order. Ties broken by x
        // (left-edge) so columns read left-to-right. Deliberate
        // divergence from iOS's `(center-y, x)` rule — see the
        // "Android divergence" callout under §2.5 of
        // `DESCRIBE_UI_OUTLINE.md`.
        let sorted = cleaned.sorted { a, b in
            if a.frame.y != b.frame.y { return a.frame.y < b.frame.y }
            return a.frame.x < b.frame.x
        }
        let deduped = dedup(sorted)

        // List detection must match the set of roots we actually
        // rendered. If we collapsed multi-window and only emitted
        // popup contents, running the list detector over the
        // active-window subtree would emit ghost `#N` summaries
        // pointing at chat rows the user can no longer see.
        let detectionRoot: ElementNode = {
            guard root.className == multiWindowMarker,
                  topLevelNodes.count != root.children.count else {
                return root
            }
            return ElementNode(
                resourceId: "",
                package: root.package,
                className: "",
                text: "",
                contentDescription: "",
                boundsInScreen: root.boundsInScreen,
                children: topLevelNodes
            )
        }()
        let clusters = AndroidListDetector.detect(root: detectionRoot)
        // Attribute list aliases to surviving outline entries in two passes:
        //
        //   1. Exact frame equality — covers the common case where the
        //      ListView's direct child is also what survives folding /
        //      dropRedundantOuter. Cheap dict lookup keyed by frame.
        //
        //   2. Containment — for each cell that didn't find an exact
        //      match, award the alias to the entry whose frame is fully
        //      contained in the cell frame and has the largest area
        //      (the most "row-like" surviving descendant). This handles
        //      the case where the ListView's direct child is a thin
        //      padding wrapper (e.g. 1000×226 at y=733) that gets
        //      unwrapped down to its inner content (1000×194 at y=765)
        //      so the outer-frame key in the dict misses, even though
        //      the entry the user sees IS that list row.
        //
        // Each entry can carry at most one alias, picked by the first
        // cluster (lowest scope) that claims it — so scope-1 always
        // wins over scope-2 for the same row, even if both lists nest.
        var aliasByEntryIndex: [Int: Outline.ListAlias] = [:]
        var summaries: [Outline.ListSummary] = []
        for (rank, cluster) in clusters.enumerated() {
            let scope = rank + 1
            for (i, cellFrame) in cluster.cellFrames.enumerated() {
                let alias = Outline.ListAlias(scope: scope, index: i + 1)
                // Pass 1 — exact match.
                if let exactIdx = deduped.firstIndex(where: { $0.frame == cellFrame }),
                   aliasByEntryIndex[exactIdx] == nil {
                    aliasByEntryIndex[exactIdx] = alias
                    continue
                }
                // Pass 2 — best-contained fallback.
                var bestIdx: Int? = nil
                var bestArea = -1
                for (idx, item) in deduped.enumerated() {
                    if aliasByEntryIndex[idx] != nil { continue }
                    guard frameContains(cellFrame, item.frame) else { continue }
                    let area = item.frame.width * item.frame.height
                    if area > bestArea {
                        bestArea = area
                        bestIdx = idx
                    }
                }
                if let idx = bestIdx {
                    aliasByEntryIndex[idx] = alias
                }
            }
            summaries.append(Outline.ListSummary(
                scope: scope,
                cellCount: cluster.cellFrames.count,
                cellHeight: cluster.cellHeight,
                containerRole: cluster.containerRole,
                containerLabel: cluster.containerLabel,
                bbox: cluster.frame,
                score: cluster.score
            ))
        }

        var entries: [Outline.Entry] = []
        entries.reserveCapacity(deduped.count)
        for (idx, item) in deduped.enumerated() {
            let region = item.declaredRegion ?? yBandRegion(for: item.frame, screenHeight: screen.height)
            let alias = aliasByEntryIndex[idx]
            let states = AndroidClassifier.stateTags(role: item.role, node: item.node, label: item.label)
            let value = AndroidClassifier.effectiveValue(node: item.node, label: item.label)
            let resourceId = item.node.resourceIdShortName.isEmpty ? nil : item.node.resourceIdShortName
            let hint: String? = {
                guard let raw = item.node.hintText, !raw.isEmpty else { return nil }
                return raw
            }()
            // Reads `item.uniqueId` (the fold-aware copy) rather than
            // `item.node.uniqueId` so a folded entry carries its
            // inner child's id forward — see the `Working.uniqueId`
            // doc comment.
            let uniqueId: String? = {
                guard let raw = item.uniqueId, !raw.isEmpty else { return nil }
                return raw
            }()
            entries.append(Outline.Entry(
                aliases: Outline.Aliases(at: idx + 1, list: alias),
                role: item.role,
                label: item.label,
                frame: item.frame,
                region: region,
                states: states,
                uniqueId: uniqueId,
                value: value,
                resourceId: resourceId,
                hint: hint,
                depth: item.depth
            ))
        }

        // Re-order entries into the print order the agent actually
        // sees: canonical region order (Top → declared → Content →
        // Bottom) with DFS preorder inside each region. Then renumber
        // each entry's `at` so `@1, @2, @3, …` walks the outline top
        // to bottom. Without this step the y-sorted creation order
        // leaks into `at`, and Viewer's ↑/↓ navigation jumps around
        // for nested groups whose DFS sibling order doesn't match y.
        let (canonical, indentDepths) = reorderInCanonicalPrintOrder(entries, screen: screen)

        let text = renderText(
            appLabel: appLabel,
            screen: screen,
            entries: canonical,
            indentDepths: indentDepths
        )
        return Outline(text: text, entries: canonical, lists: summaries, screen: screen, appLabel: appLabel)
    }

    /// Reorders `entries` to match the print order produced by
    /// `renderText` (canonical region order + DFS preorder per
    /// region) and rewrites each entry's `aliases.at` to its new
    /// 1-based position. The `aliases.list` field stays bound to its
    /// entry — list aliases were computed against frame, not index,
    /// so they survive the reshuffle.
    ///
    /// Returns the reordered entries **and** a parallel `[Int]` of
    /// indent depths so `renderText` doesn't have to recompute the
    /// same O(n²) parent-discovery a second time. The depths are
    /// **uncapped** here; `renderText` caps at 2 when it converts
    /// to spaces.
    private static func reorderInCanonicalPrintOrder(
        _ entries: [Outline.Entry],
        screen: Outline.Frame
    ) -> (entries: [Outline.Entry], indentDepths: [Int]) {
        // Bucket per region, preserve first-appearance order to seed
        // the canonical sort below.
        var regionsInOrder: [RegionKey] = []
        var bucketIndicesByRegion: [RegionKey: [Int]] = [:]
        for (i, e) in entries.enumerated() {
            let key = RegionKey(kind: e.region.kind, label: e.region.label)
            if bucketIndicesByRegion[key] == nil { regionsInOrder.append(key) }
            bucketIndicesByRegion[key, default: []].append(i)
        }
        regionsInOrder.sort { a, b in
            let rank: (String) -> Int = {
                switch $0 {
                case "Top":     return 0
                case "Bottom":  return 3
                case "Content": return 2
                default:        return 1  // NavBar / TabBar / declared regions
                }
            }
            return rank(a.kind) < rank(b.kind)
        }

        // Walk each bucket in DFS preorder; concat across regions.
        // `depths` carries the indent depth per ordered entry so
        // renderText can read it back without recomputing.
        var orderedOriginalIndices: [Int] = []
        var depths: [Int] = []
        orderedOriginalIndices.reserveCapacity(entries.count)
        depths.reserveCapacity(entries.count)
        for region in regionsInOrder {
            let bucketIndices = bucketIndicesByRegion[region] ?? []
            let bucketEntries = bucketIndices.map { entries[$0] }
            let layout = computeIndentLayout(bucketEntries, screen: screen)
            for (positionInBucket, depth) in layout {
                orderedOriginalIndices.append(bucketIndices[positionInBucket])
                depths.append(depth)
            }
        }

        // Rebuild entries in this order, renumbering `at`.
        let renumbered = orderedOriginalIndices.enumerated().map { (newPosition, originalIndex) -> Outline.Entry in
            let e = entries[originalIndex]
            return Outline.Entry(
                aliases: Outline.Aliases(at: newPosition + 1, list: e.aliases.list),
                role: e.role,
                label: e.label,
                frame: e.frame,
                region: e.region,
                states: e.states,
                uniqueId: e.uniqueId,
                value: e.value,
                resourceId: e.resourceId,
                hint: e.hint,
                depth: depths[newPosition]
            )
        }
        return (renumbered, depths)
    }

    // MARK: - Walk

    private static func walk(
        node: ElementNode,
        depth: Int,
        declared: Outline.Region?,
        screen: Outline.Frame,
        options: RendererOptions,
        siblingIdRepeats: Bool,
        into collected: inout [Working]
    ) {
        let newRegion: Outline.Region? = declared == nil ? AndroidClassifier.declaredRegion(for: node) : nil
        let effective = declared ?? newRegion

        let frame = node.boundsInScreen.toFrame()
        let role = AndroidClassifier.role(for: node)
        let label = primaryLabel(for: node)

        let isRegionWrapper = newRegion != nil
        if !isRegionWrapper && includeNode(node, frame: frame, screen: screen, label: label, role: role, options: options, siblingIdRepeats: siblingIdRepeats) {
            collected.append(Working(
                node: node, frame: frame, depth: depth,
                declaredRegion: effective, role: role, label: label,
                uniqueId: node.uniqueId
            ))
        }

        // `SlidingPaneLayout` (androidx Material list/detail pattern,
        // used by LINE's `LineUserSettingsTwoPaneFragmentActivity` for
        // every Settings drill-down) keeps BOTH the master pane and
        // the detail pane attached, with identical full-screen bounds
        // in narrow-screen single-pane mode. Only the open pane is
        // drawn but a11y reports both subtrees — so every Settings →
        // Account / Privacy / etc. outline used to ghost the master
        // pane's rows under the detail's. Drop the master subtree
        // (pane[0]) when both panes are populated and overlap.
        // Tablet two-pane mode lays panes side-by-side at different x,
        // so the bounds-equal check naturally skips the drop and
        // surfaces both panes.
        let childIdCounts = repeatingShortIdCount(among: node.children)
        if shouldDropMasterPaneOfSlidingPane(node) {
            for (idx, child) in node.children.enumerated() {
                if idx == 0 { continue }
                let repeats = childIdCounts[child.resourceIdShortName, default: 0] >= 2
                walk(node: child, depth: depth + 1, declared: effective, screen: screen, options: options,
                     siblingIdRepeats: repeats, into: &collected)
            }
            return
        }

        for child in node.children {
            let repeats = childIdCounts[child.resourceIdShortName, default: 0] >= 2
            walk(node: child, depth: depth + 1, declared: effective, screen: screen, options: options,
                 siblingIdRepeats: repeats, into: &collected)
        }
    }

    /// Count how often each non-empty `resourceIdShortName` appears
    /// among a node's direct children. Used by `walk` to thread a
    /// "this child's id repeats among its siblings" signal into
    /// `includeNode`, which exempts empty-label pure-container Views
    /// from the structural-wrapper drop when they're part of a
    /// repeating list-cell pattern (`:select_invitee_info_row_background:`
    /// repeated 8× under a ListView). Empty ids are intentionally
    /// excluded — every label-less FrameLayout would otherwise look
    /// "repeating" because resourceIdShortName defaults to "".
    private static func repeatingShortIdCount(among children: [ElementNode]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for child in children {
            let id = child.resourceIdShortName
            if id.isEmpty { continue }
            counts[id, default: 0] += 1
        }
        return counts
    }

    /// True when `node` is a `SlidingPaneLayout` with exactly two
    /// children whose `boundsInScreen` are equal AND both subtrees
    /// have at least one labelled descendant — i.e. single-pane mode
    /// is open on the detail and the master is the ghost layer.
    private static func shouldDropMasterPaneOfSlidingPane(_ node: ElementNode) -> Bool {
        // Anchor to the canonical class name (suffix or exact). A
        // bare `.contains("SlidingPaneLayout")` would also fire on
        // third-party wrappers like `com.acme.MySlidingPaneLayoutWrapper`
        // and silently drop their first child subtree — those wrappers
        // are not behaviourally equivalent to the androidx component
        // and need to render normally.
        let cls = node.className
        let isCanonical = cls == "androidx.slidingpanelayout.widget.SlidingPaneLayout"
            || cls.hasSuffix(".SlidingPaneLayout")
        guard isCanonical else { return false }
        guard node.children.count == 2 else { return false }
        let pane0 = node.children[0].boundsInScreen
        let pane1 = node.children[1].boundsInScreen
        guard pane0 == pane1 else { return false }
        return subtreeHasLabelledDescendant(node.children[0])
            && subtreeHasLabelledDescendant(node.children[1])
    }

    private static func subtreeHasLabelledDescendant(_ node: ElementNode) -> Bool {
        if !primaryLabel(for: node).isEmpty { return true }
        for child in node.children {
            if subtreeHasLabelledDescendant(child) { return true }
        }
        return false
    }

    // MARK: - Helpers

    private static func appLabel(for root: ElementNode) -> String {
        if !root.contentDescription.isEmpty { return root.contentDescription }
        if !root.text.isEmpty { return root.text }
        if !root.package.isEmpty { return root.package }
        return "App"
    }

    private static func primaryLabel(for node: ElementNode) -> String {
        // Some apps push the literal four-character string "null" into
        // contentDescription / text (Java toString of a null reference,
        // or a placeholder constant that escaped). Treat both as empty
        // so we don't surface `Image "null"` rows.
        let cd = node.contentDescription
        if !cd.isEmpty, cd != "null" { return cd }
        let text = node.text
        if !text.isEmpty, text != "null" {
            if let hint = node.hintText, hint == text { return "" }
            return text
        }
        return ""
    }

    private static func includeNode(
        _ node: ElementNode,
        frame: Outline.Frame,
        screen: Outline.Frame,
        label: String,
        role: String,
        options: RendererOptions,
        siblingIdRepeats: Bool
    ) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }

        // Drop nodes the framework reports as not currently visible
        // to the user. LINE-observed shape on the Settings → Account
        // transition: the previous fragment's view tree is still in
        // the a11y root, has on-screen `boundsInScreen` matching the
        // new fragment's row positions, but `isVisibleToUser()` is
        // false. Surfacing those would mislead the agent into tapping
        // ghost rows. Bridges from before the wire bump default this
        // to `true`, so behaviour is unchanged for stale bridges.
        guard node.visibleToUser else { return false }

        if options.filterOffscreen, screen.width > 0, screen.height > 0 {
            // `frame` and `screen` are both in absolute device-pixel
            // coordinates: `screen` is the host window's bounds, which
            // for floating popups / dialogs starts at a non-zero
            // (screen.x, screen.y). Compare against the actual edges
            // of the screen rect, not its size — otherwise a popup at
            // (372, 274, 708×883) silently drops every node with
            // `x >= 708` or `y >= 883`.
            if frame.x + frame.width <= screen.x { return false }
            if frame.y + frame.height <= screen.y { return false }
            if frame.x >= screen.x + screen.width { return false }
            if frame.y >= screen.y + screen.height { return false }
        }

        // A node earns a row only if it carries something the agent can
        // address or interpret. We deliberately exclude:
        //
        //   * Pure `focusable=true` containers with no other signal —
        //     Android sets `focusable` on layout wrappers for keyboard /
        //     directional navigation, but they're not meaningful tap
        //     targets. (This is the `@55 ViewGroup "" (672,2114 168x223)`
        //     class of noise.) Genuine interactive widgets that *only*
        //     have `focusable=true` (rare) typically still expose a
        //     resource_id or a content description, so they survive via
        //     `hasHandle`.
        //
        //   * Raw `text == hintText` cases — `primaryLabel` already
        //     collapses those to `""`, so checking `label` instead of
        //     `node.text` directly drops empty EditTexts whose only
        //     "content" is the placeholder. (Empty EditTexts stay
        //     visible via `clickable` / resource_id.)
        let hasHandle = !label.isEmpty
            || !node.resourceIdShortName.isEmpty
            || !(node.uniqueId ?? "").isEmpty
        let interactable = node.clickable
            || node.longClickable
            || node.scrollable
            || node.checkable
        guard hasHandle || interactable else { return false }

        // Drop full-screen structural wrappers + backgrounds:
        //   * label empty
        //   * frame covers ≥ 80% of the screen
        //   * not click/long-click/checkable (scroll is allowed: a
        //     scrollable full-screen wrapper like ViewPager is still
        //     noise — users address it via the `swipe` verb at
        //     coords, not by selecting this row).
        //
        // Covers two LINE-observed shapes:
        //   * Pure layout primitives — `:action_bar_root:`,
        //     `:content:`, `:app_main_root:`, `:viewpager:`,
        //     `:home_tab_header_background:`, etc.
        //   * Full-screen background imagery — `:chat_ui_main_skin_view:`
        //     (an `ImageView` covering 1080×2400 behind the entire
        //     chat history), splash backgrounds.
        // Neither is addressable by the agent and both clutter the
        // outline with one giant frame.
        let actionableBeyondScroll = node.clickable || node.longClickable || node.checkable
        if label.isEmpty,
           !actionableBeyondScroll,
           screen.width > 0, screen.height > 0,
           isFullScreen(frame: frame, screen: screen) {
            return false
        }
        // Drop label-less, non-interactable pure-container nodes
        // outright. They are the structural skeleton (
        // `:actions_header_item_container:`, `:multiprofile_item_title:`,
        // `:bgm_item_title_group:`, `:create_album_view_container:`,
        // `:seamless_header_background:` etc.) that exists only to
        // host child widgets. Their resource_id alone isn't enough
        // to be addressable: nothing inside them is uniquely keyed
        // off the wrapper, and tapping the wrapper does nothing.
        //
        // `scrollable` keeps the wrapper alive — RecyclerView /
        // NestedScrollView genuinely need a row so `swipe` / `scroll`
        // verbs can target them by id. Same goes for the explicit
        // declared-region containers (Toolbar / BottomNavigationView)
        // which are classified into NavBar/TabBar regions instead of
        // pureContainerClasses.
        //
        // Exemption: when this node's `resourceIdShortName` repeats
        // among its siblings (≥ 2 occurrences under the same parent),
        // it's almost certainly a list-cell row container that LINE
        // failed to mark `clickable` (e.g. `:select_invitee_info_row_
        // background:` on a row whose contact is already selected).
        // Dropping it would orphan the row's children — thumbnail,
        // name, etc. — at the top level, breaking the list-cell
        // grouping the agent relies on. Skeleton wrappers like
        // `:action_bar_root:` show up exactly once per screen, so
        // they don't trip this exemption.
        if label.isEmpty,
           !actionableBeyondScroll,
           !node.scrollable,
           !siblingIdRepeats,
           Self.pureContainerClasses.contains(node.className) {
            return false
        }
        // Drop label-less pure-container nodes that are too thin to
        // be a useful tap target — LINE sets `clickable=true` on
        // `:setting_spacer:` (1080×60) and `:setting_divider:`
        // (996×3) so finger-up gestures don't leak through the gap
        // between rows. They satisfy the `interactable` test above
        // and would otherwise survive `includeNode`, but they aren't
        // anything the agent should be selecting. A real button is
        // at least ~60×60 (≈ 22dp at xxhdpi); below that we treat
        // the entry as decoration regardless of clickability.
        if label.isEmpty,
           (node.uniqueId ?? "").isEmpty,
           !node.scrollable,
           !node.checkable,
           min(frame.width, frame.height) <= 60,
           Self.pureContainerClasses.contains(node.className) {
            return false
        }
        return true
    }

    private static let pureContainerClasses: Set<String> = [
        "android.view.View",
        "android.view.ViewGroup",
        "android.widget.FrameLayout",
        "android.widget.LinearLayout",
        "android.widget.RelativeLayout",
        "android.widget.ScrollView",
        "androidx.core.widget.NestedScrollView",
        "androidx.constraintlayout.widget.ConstraintLayout",
        "androidx.coordinatorlayout.widget.CoordinatorLayout",
        "androidx.viewpager.widget.ViewPager",
        "androidx.viewpager2.widget.ViewPager2",
    ]

    private static func isFullScreen(frame: Outline.Frame, screen: Outline.Frame) -> Bool {
        let area = frame.width * frame.height
        let screenArea = screen.width * screen.height
        guard screenArea > 0 else { return false }
        // Threshold tuned for the chat-list test case: 1080x179 cells
        // are 8% of the screen and must survive; `:action_bar_root:`
        // and friends are 100%. 80% is a safe gap.
        return area * 100 >= screenArea * 80
    }

    /// Fold "clickable wrapper + single label-bearing descendant" pairs into
    /// one entry. Android UIs routinely place a `clickable=true` View as a
    /// tap shim above a labelless layout that owns a single TextView — both
    /// pass `includeNode` (the wrapper via `clickable`, the leaf via label)
    /// and result in two outline rows for what the user sees as one button.
    /// The fold collapses them: keep the wrapper's frame + interactivity
    /// (so taps land on the larger hit-zone) but adopt the leaf's label and
    /// promote `role` to `"Button"` when the wrapper is `clickable`.
    ///
    /// Strict guards keep this from over-eating:
    ///   * The wrapper must have an empty `label` and be `clickable` /
    ///     `longClickable` / `focusable`.
    ///   * It must have exactly **one** label-bearing descendant in the
    ///     collected set. Two labels means the wrapper is a row, not a
    ///     button — both stay.
    ///   * The descendant must also have an empty `resourceId` / `uniqueId`
    ///     (i.e. nothing the agent might want to address by id), or the
    ///     wrapper must already share the same id. This preserves
    ///     selectable inner nodes when the app deliberately exposed them.
    private static func foldContainerText(_ items: [Working]) -> [Working] {
        // wrapper idx → primary descendant idx whose label fills the fold
        var foldMap: [Int: Int] = [:]
        // wrapper idx → additional decorative descendants to drop (the
        // Image "Close" / generic icons nested inside the chosen
        // descendant's frame)
        var sweepMap: [Int: Set<Int>] = [:]
        var fold: [Int: Working] = [:]

        // Pre-compute the labeled-entry index set once. The inner
        // candidate scan only ever cares about labeled descendants
        // (line 561 of the old code's `!candidate.label.isEmpty`
        // guard), and most items in a typical screen are unlabeled
        // structural wrappers / icons. Iterating the full `items`
        // for every wrapper was O(n²) over a noisy haystack; the
        // labeled subset is usually <30% of `items`.
        let labeledIndices = items.indices.filter { !items[$0].label.isEmpty }

        for (i, wrapper) in items.enumerated() {
            guard wrapper.label.isEmpty else { continue }
            guard wrapper.node.clickable || wrapper.node.longClickable || wrapper.node.focusable else { continue }

            // Collect every labeled descendant inside the wrapper.
            var labeled: [Int] = []
            for j in labeledIndices where j != i {
                let candidate = items[j]
                guard candidate.depth > wrapper.depth else { continue }
                guard frameContains(wrapper.frame, candidate.frame) else { continue }
                labeled.append(j)
            }
            guard let minDepth = labeled.map({ items[$0].depth }).min() else { continue }
            let shallowest = labeled.filter { items[$0].depth == minDepth }
            // Ambiguous: two labels at the same shallowest depth (e.g.
            // a chat row with name + timestamp + preview siblings) are
            // a row of distinct info, not a button. Skip fold.
            guard shallowest.count == 1 else { continue }
            let chosenIdx = shallowest[0]
            let chosen = items[chosenIdx]

            // Don't fold over an interactable child — it's a real
            // sub-button users may want to address separately. A
            // non-interactable child's id is decorative (it can't be
            // tapped on its own), so adopting the wrapper as the tap
            // target is safe even when the child has an id.
            if chosen.node.clickable || chosen.node.longClickable || chosen.node.checkable { continue }

            foldMap[i] = chosenIdx

            // Sweep up other labeled-but-noisy descendants nested
            // INSIDE the chosen one. The LINE header-button shape is
            //   LinearLayout (clickable, label="")
            //     FrameLayout :header_button_layout: (label="Settings button")
            //       Image :header_button_img: (label="Close")
            // The redundant FrameLayout / View / LinearLayout middle
            // layers are noise once the wrapper has adopted their
            // label, so sweep them. We deliberately keep Images
            // visible regardless — an Image inside a button is
            // usually the icon (the row's avatar, an OA badge, a
            // "Close" glyph) and the agent often wants to address it
            // or just sanity-check what's painted. The cost of one
            // extra outline row per button is cheaper than silently
            // dropping content the user can see on screen.
            var sweep: Set<Int> = []
            for j in labeled where j != chosenIdx {
                let other = items[j]
                if other.node.clickable || other.node.longClickable || other.node.checkable { continue }
                if other.role.contains("Image") { continue }
                if frameContains(chosen.frame, other.frame) {
                    sweep.insert(j)
                }
            }
            sweepMap[i] = sweep

            // Promote on `longClickable` too — long-press-only
            // wrappers are still buttons from a user-tap perspective
            // (the iOS-style "context menu" trigger), and skill
            // authors selecting with `--element-type Button` would
            // otherwise miss them.
            let role = (wrapper.node.clickable || wrapper.node.longClickable)
                ? "Button"
                : chosen.role
            // Prefer the inner child's `uniqueId` when it carries one:
            // the wrapper-no-id + child-with-id shape is how Compose
            // emits "Modifier.testTag(...)" landmarks one layer
            // below the clickable wrapper, and dropping the id here
            // makes `tap --id <testTag>` silently fail.
            let foldedUniqueId: String?
            if let inner = chosen.node.uniqueId, !inner.isEmpty {
                foldedUniqueId = inner
            } else {
                foldedUniqueId = wrapper.node.uniqueId
            }
            fold[i] = Working(
                node: wrapper.node,
                frame: wrapper.frame,
                depth: wrapper.depth,
                declaredRegion: wrapper.declaredRegion,
                role: role,
                label: chosen.label,
                uniqueId: foldedUniqueId
            )
        }

        var dropped = Set(foldMap.values)
        for set in sweepMap.values { dropped.formUnion(set) }
        var out: [Working] = []
        out.reserveCapacity(items.count - dropped.count)
        for (i, item) in items.enumerated() {
            if dropped.contains(i) { continue }
            if let folded = fold[i] { out.append(folded) } else { out.append(item) }
        }
        return out
    }

    /// Drop a "decorative outer" entry when a same-frame deeper entry
    /// is the real button (clickable + labelled). Mirror case of
    /// `foldContainerText`: there the outer was clickable and the
    /// inner just carried the label. Here the inner is clickable AND
    /// carries the label, while the outer is a labelless structural
    /// wrapper whose only contribution is a resource_id. Real-world
    /// example from LINE's chat header:
    ///   `LinearLayout :left_header_button:` (clickable=false, cd="")
    ///     `FrameLayout :header_button_layout:` (clickable=true, cd="Search button")
    /// Without this pass both surface as outline rows at identical
    /// coordinates. The agent only needs the clickable one.
    private static func dropRedundantOuter(_ items: [Working]) -> [Working] {
        // Same precompute as `foldContainerText`: the inner candidate
        // must be (a) labeled and (b) interactable. Precomputing the
        // labeled+interactable index set lets each outer skip
        // the structural majority of `items` straight away.
        let candidates = items.indices.filter { idx in
            let it = items[idx]
            guard !it.label.isEmpty else { return false }
            return it.node.clickable || it.node.longClickable || it.node.checkable
        }
        // Frame-keyed lookup so each outer only touches inners that
        // share its bounding box. Identical-frame inners are the
        // only ones that can trigger the drop (line `inner.frame
        // == outer.frame` below).
        var candidatesByFrame: [Outline.Frame: [Int]] = [:]
        for idx in candidates {
            candidatesByFrame[items[idx].frame, default: []].append(idx)
        }
        var dropped: Set<Int> = []
        for (i, outer) in items.enumerated() {
            guard outer.label.isEmpty else { continue }
            let outerInteractable = outer.node.clickable || outer.node.longClickable || outer.node.checkable
            guard !outerInteractable else { continue }
            let frameMatches = candidatesByFrame[outer.frame] ?? []
            for j in frameMatches where i != j {
                let inner = items[j]
                guard inner.depth > outer.depth else { continue }
                dropped.insert(i)
                break
            }
        }
        guard !dropped.isEmpty else { return items }
        return items.enumerated().compactMap { dropped.contains($0.offset) ? nil : $0.element }
    }

    private static func frameContains(_ outer: Outline.Frame, _ inner: Outline.Frame) -> Bool {
        outer.x <= inner.x
            && outer.y <= inner.y
            && outer.x + outer.width >= inner.x + inner.width
            && outer.y + outer.height >= inner.y + inner.height
    }

    private struct DedupKey: Hashable {
        let role: String
        let label: String
        let frame: Outline.Frame
    }

    private static func dedup(_ items: [Working]) -> [Working] {
        var bestIndex: [DedupKey: Int] = [:]
        for (i, item) in items.enumerated() {
            let key = DedupKey(role: item.role, label: item.label, frame: item.frame)
            if let prev = bestIndex[key] {
                if item.depth > items[prev].depth { bestIndex[key] = i }
            } else {
                bestIndex[key] = i
            }
        }
        let survivors = Set(bestIndex.values)
        var out: [Working] = []
        out.reserveCapacity(survivors.count)
        for (i, item) in items.enumerated() where survivors.contains(i) { out.append(item) }
        return out
    }

    private static func yBandRegion(for frame: Outline.Frame, screenHeight: Int) -> Outline.Region {
        guard screenHeight > 0 else { return Outline.Region(kind: "Content", label: nil) }
        // Full-screen wrappers (cover images, modal backgrounds,
        // action_bar_root) span > 50% of the screen — they're "the
        // page", not chrome. Keep them in Content even when their
        // center happens to fall inside the Top or Bottom band.
        let isFullPageish = frame.height > screenHeight / 2
        if !isFullPageish {
            let yc = frame.y + frame.height / 2
            if yc < yBandInset { return Outline.Region(kind: "Top", label: nil) }
            if yc >= screenHeight - yBandInset { return Outline.Region(kind: "Bottom", label: nil) }
        }
        return Outline.Region(kind: "Content", label: nil)
    }

    // MARK: - Text rendering

    private struct RegionKey: Hashable {
        let kind: String
        let label: String?
    }

    /// `entries` MUST already be in canonical print order (the
    /// shape `reorderInCanonicalPrintOrder` produces). `indentDepths`
    /// is parallel to `entries` and carries the pre-computed DFS
    /// depth so we don't have to re-run the O(n²) parent-discovery
    /// here. Indent is capped at 2 levels (max 4 spaces) — past
    /// that the outline feels like a tree dump rather than a table
    /// and the readability gain inverts.
    private static func renderText(
        appLabel: String,
        screen: Outline.Frame,
        entries: [Outline.Entry],
        indentDepths: [Int]
    ) -> String {
        var out = ""
        if screen.width > 0, screen.height > 0 {
            out.append("App: \(appLabel)  \(screen.width)x\(screen.height)\n")
        } else {
            out.append("Subtree: \(appLabel)\n")
        }
        if entries.isEmpty { return out }

        precondition(
            entries.count == indentDepths.count,
            "indentDepths must be parallel to entries"
        )

        // Walk canonical entries linearly, emitting a region header
        // each time the region key changes (entries are already
        // bucketed in canonical region order by the reorder pass).
        var previousRegion: RegionKey? = nil
        for (i, entry) in entries.enumerated() {
            let regionKey = RegionKey(kind: entry.region.kind, label: entry.region.label)
            if regionKey != previousRegion {
                out.append("\n")
                out.append(regionHeader(regionKey, screenHeight: screen.height))
                out.append("\n")
                previousRegion = regionKey
            }
            let level = min(indentDepths[i], 2)
            out.append(elementLine(entry, indent: level * 2))
            out.append("\n")
        }
        return out
    }

    /// Returns `(entryIndex, depth)` pairs in DFS preorder.
    ///
    /// For each entry, the "parent" is the smallest preceding bucket
    /// entry whose frame strictly contains it AND qualifies as a
    /// container:
    ///
    ///   1. Role must not be a leaf (TextView / Image / TextField).
    ///      Leaves never visually own subsequent siblings even when
    ///      their frame coincidentally contains another entry.
    ///   2. Either the candidate carries a `#N` list alias (legit
    ///      list containers can be tall and still anchor their
    ///      cells), or its frame.height is ≤ 60 % of the screen. The
    ///      height clamp excludes page-wide content backdrops like
    ///      `View "Home" (0,132 1080x2205)` from swallowing the
    ///      entire page into indent-2.
    ///   3. The candidate must strictly contain the entry — identical
    ///      frames are excluded so post-dedup ties never claim
    ///      parenthood over their twin.
    ///
    /// Multiple candidates → smallest area wins (the deepest visible
    /// ancestor still in the bucket).
    ///
    /// The walk relies on `entries` being sorted y-then-x: parents
    /// always strictly contain their children, and containment
    /// implies `parent.y ≤ child.y` (with `parent.x ≤ child.x` on
    /// ties), so a parent is guaranteed to appear before its child
    /// in `entries`. That's what makes the "look back over preceding
    /// entries only" formulation correct.
    ///
    /// O(n²) per region for parent discovery + O(n) for the DFS
    /// emit. Real bucket sizes are dozens to ~200 entries, well
    /// under a millisecond.
    ///
    /// DFS emit is implemented as an explicit stack rather than a
    /// recursive inner function. Compose hierarchies routinely
    /// produce 100+ nested wrappers before fold/dedup collapses
    /// them; a recursive emit would consume one Swift stack frame
    /// per level and risk overflow on long-running daemon
    /// sessions. The iterative form is O(n) heap-only.
    private static func computeIndentLayout(
        _ entries: [Outline.Entry],
        screen: Outline.Frame
    ) -> [(entryIndex: Int, depth: Int)] {
        let leafRoles: Set<String> = ["TextView", "Image", "TextField"]
        let n = entries.count
        if n == 0 { return [] }

        var parents = [Int?](repeating: nil, count: n)
        for i in 0..<n {
            let e = entries[i]
            var bestParent: Int? = nil
            var bestArea = Int.max
            for j in 0..<i {
                let p = entries[j]
                if leafRoles.contains(p.role) { continue }
                if screen.height > 0,
                   p.aliases.list == nil,
                   p.frame.height * 10 > screen.height * 6 {
                    continue
                }
                if p.frame == e.frame { continue }
                guard frameContains(p.frame, e.frame) else { continue }
                let area = p.frame.width * p.frame.height
                if area < bestArea {
                    bestArea = area
                    bestParent = j
                }
            }
            parents[i] = bestParent
        }

        // Children buckets — preserve y-then-x order via the input
        // index, which is already sorted that way.
        var childrenOf = [Int: [Int]]()
        var topLevel: [Int] = []
        for i in 0..<n {
            if let p = parents[i] {
                childrenOf[p, default: []].append(i)
            } else {
                topLevel.append(i)
            }
        }

        // Iterative DFS preorder emit using an explicit stack. Each
        // stack entry remembers where in the child list it left off
        // so the walk produces the same order a recursive `for
        // child in children { recurse(child) }` would.
        var out: [(Int, Int)] = []
        out.reserveCapacity(n)
        struct Frame { let index: Int; let depth: Int; var cursor: Int }
        // Push roots in reverse so the first root is processed
        // first when we pop from the back of `stack` below.
        var stack: [Frame] = []
        stack.reserveCapacity(n)
        for root in topLevel.reversed() {
            stack.append(Frame(index: root, depth: 0, cursor: -1))
        }
        while !stack.isEmpty {
            var top = stack.removeLast()
            if top.cursor == -1 {
                // First visit — emit before descending.
                out.append((top.index, top.depth))
                top.cursor = 0
            }
            let children = childrenOf[top.index, default: []]
            if top.cursor < children.count {
                let child = children[top.cursor]
                top.cursor += 1
                stack.append(top)
                stack.append(Frame(index: child, depth: top.depth + 1, cursor: -1))
            }
            // else: this subtree is done; do not re-push `top`.
        }
        return out
    }

    private static func regionHeader(_ key: RegionKey, screenHeight: Int) -> String {
        let hasScreen = screenHeight > 0
        switch key.kind {
        case "Top":
            return hasScreen ? "[Top  y<\(yBandInset)]" : "[Top]"
        case "Content":
            if hasScreen {
                let upper = max(yBandInset, screenHeight - yBandInset)
                return "[Content  y=\(yBandInset)..\(upper)]"
            }
            return "[Content]"
        case "Bottom":
            if hasScreen {
                return "[Bottom  y>=\(max(yBandInset, screenHeight - yBandInset))]"
            }
            return "[Bottom]"
        default:
            if let label = key.label {
                return "[\(key.kind)  \"\(TruncationHelpers.escape(label))\"]"
            }
            return "[\(key.kind)]"
        }
    }

    private static func elementLine(_ entry: Outline.Entry, indent: Int = 0) -> String {
        var prefix = "@\(entry.aliases.at)"
        if let list = entry.aliases.list {
            if list.scope <= 1 {
                prefix += " #\(list.index)"
            } else {
                prefix += " #\(list.index)@\(list.scope)"
            }
        }
        let label = TruncationHelpers.escapeAndTruncate(entry.label, maxGraphemes: 60)
        let frame = "(\(entry.frame.x),\(entry.frame.y) \(entry.frame.width)x\(entry.frame.height))"
        let pad = indent > 0 ? String(repeating: " ", count: indent) : ""
        var line = "  \(pad)\(prefix)  \(entry.role)  \"\(label)\""
        // Stable-identifier hints, both addressable via `--id <X>`:
        //
        //   * `uniqueId` (from `setAccessibilityUniqueId`, API 33+).
        //     Guaranteed unique by the app. Rendered as `#name`,
        //     mirroring iOS AXUniqueId.
        //
        //   * `resource_id` — short-name from layout XML. CAN repeat
        //     across instances (every list cell, every dialog button).
        //     Rendered as `:name:` (Slack-emoji-style colons) so it's
        //     visually distinct from `#uniqueId` and the reader knows
        //     to expect possible ambiguity. Selector resolution
        //     surfaces a clear "matched N elements" error when it
        //     does collide.
        if let uniqueId = entry.uniqueId {
            line += "  #\(uniqueId)"
        }
        if let resourceId = entry.resourceId {
            line += "  :\(resourceId):"
        }
        line += "  \(frame)"
        for tag in entry.states { line += "  \(tag)" }
        return line
    }
}