// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Renders an accessibility tree into the human-readable outline format
/// defined in `DESCRIBE_UI_OUTLINE.md`.
///
/// The formatter is a pure function over a decoded `AccessibilityElement`
/// tree. No I/O, no simulator access. Separating rendering from the
/// describe-ui command keeps it trivially testable with fixture trees
/// and lets other callers (future list-detection pipeline, alternative
/// renderers) reuse the same pipeline.
public enum OutlineFormatter {
    /// AX types that may be promoted to a region when they carry a
    /// non-empty label. The value is the short-role rendered in the
    /// `[TabBar "..."]`-style header.
    public static let declaredRegionKinds: [String: String] = [
        "NavigationBar": "NavBar",
        "TabBar": "TabBar",
        "Toolbar": "Toolbar",
        "ScrollView": "Scroll",
        "Group": "Group",
    ]

    /// Types whose `AXValue == "1"` surfaces as a `selected` state tag.
    private static let selectableTypes: Set<String> = [
        "Tab", "RadioButton", "SegmentedControl", "Switch", "CheckBox",
    ]

    /// Types whose non-empty `AXValue` surfaces as a `value="..."` tag.
    private static let valueBearingTypes: Set<String> = [
        "TextField", "SecureTextField", "Switch",
    ]

    /// Distance (in points) the top and bottom y-band fallbacks claim
    /// from the edges of the app frame. 120 pt covers a typical status
    /// + navigation bar above and a home indicator area below without
    /// overreaching into real content.
    public static let yBandInset = 120

    /// The `…` suffix appended to truncated strings. Kept as a constant
    /// so renderers and tests can reference the exact character.
    public static let ellipsis = "…"

    /// - Parameter foregroundBundleId: the foreground app's bundle id
    ///   resolved out-of-band (pid → `launchctl`). When supplied, the
    ///   `App:` header is reconciled against it via `ForegroundLabel` so
    ///   a stale / empty AX-root label can't make the header lie about
    ///   which app is on screen (issue #81). Defaults to nil, which
    ///   preserves the legacy tree-derived label for callers that don't
    ///   resolve the foreground.
    /// - Parameter orientationTag: non-portrait calibrated orientation
    ///   (issue #34), appended to the `App:` header so agents reading
    ///   the outline know the device is rotated. Pass nil for portrait —
    ///   the common-case header stays byte-identical to the legacy form.
    public static func render(
        tree: [AccessibilityElement],
        foregroundBundleId: String? = nil,
        orientationTag: String? = nil
    ) -> Outline {
        let root = pickRoot(tree)
        let isApplicationRoot = root?.type == "Application"

        // Only an Application root defines the screen bounds used for
        // y-band fallback and off-screen filtering. For a non-Application
        // root (e.g. `describe-ui --point` returns the single hit
        // element), use a zero screen so the renderer keeps every node
        // and falls back to the neutral `Content` region.
        let screen: Outline.Frame
        if isApplicationRoot, let appFrame = root?.frame {
            screen = Outline.Frame(
                x: 0, y: 0,
                width: Int(appFrame.width.rounded()),
                height: Int(appFrame.height.rounded())
            )
        } else {
            screen = Outline.Frame(x: 0, y: 0, width: 0, height: 0)
        }
        let fallbackLabel = root?.normalizedLabel ?? root?.type ?? "App"
        let appLabel = ForegroundLabel.reconcile(
            axRootLabel: root?.normalizedLabel,
            foregroundBundleId: foregroundBundleId,
            fallback: fallbackLabel
        )

        var collected: [Collected] = []
        if let root {
            if isApplicationRoot {
                // The Application itself is represented by the header
                // line; only its descendants become outline entries.
                for child in root.children ?? [] {
                    walk(element: child, declaredRegion: nil, depth: 1, collected: &collected)
                }
            } else {
                // Subtree / --point mode: the root is an actual element
                // the caller wants to inspect, so include it.
                walk(element: root, declaredRegion: nil, depth: 0, collected: &collected)
            }
        }

        let rounded = collected.compactMap(roundAndFilter(inside: screen))
        let deduped = deduplicate(rounded)
        // Reading-order sort uses the frame's vertical center rather than
        // its top edge. Two elements that visually share a row often have
        // different heights (e.g. a 30 pt button next to a 24 pt label at
        // top y=63 vs y=66); their tops diverge but their centers line
        // up, so center-y keeps them in left-to-right x order instead of
        // getting shuffled by the height delta.
        let sorted = deduped.sorted { lhs, rhs in
            let lhsCenterY = lhs.frame.y + lhs.frame.height / 2
            let rhsCenterY = rhs.frame.y + rhs.frame.height / 2
            if lhsCenterY != rhsCenterY { return lhsCenterY < rhsCenterY }
            return lhs.frame.x < rhs.frame.x
        }

        // Detect lists on the original tree (the algorithm depends on
        // parent-child topology, so it has to run before flattening).
        // Score-ranked, dominance order, cell sets disjoint across
        // emitted clusters.
        let clusters = ListDetector.detect(tree: tree, screenHeight: screen.height)
        var aliasByKey: [FrameRoleKey: Outline.ListAlias] = [:]
        var lists: [Outline.ListSummary] = []
        for (rank, cluster) in clusters.enumerated() {
            let scope = rank + 1
            for (cellIndex, cell) in cluster.cells.enumerated() {
                let key = FrameRoleKey(frame: cell.frame, role: cell.role)
                aliasByKey[key] = Outline.ListAlias(scope: scope, index: cellIndex + 1)
            }
            lists.append(Outline.ListSummary(
                scope: scope,
                cellCount: cluster.cells.count,
                cellHeight: cluster.cellHeight,
                containerRole: cluster.containerRole,
                containerLabel: cluster.containerLabel,
                bbox: cluster.bbox,
                score: cluster.score
            ))
        }

        var entries: [Outline.Entry] = []
        entries.reserveCapacity(sorted.count)
        for (index, item) in sorted.enumerated() {
            let element = item.collected.element
            let region = item.collected.declaredRegion
                ?? yBandRegion(for: item.frame, screenHeight: screen.height)
            let uniqueId: String? = {
                guard let raw = element.normalizedUniqueId, !raw.isEmpty else { return nil }
                return raw
            }()
            let role = element.type ?? "Element"
            let listAlias = aliasByKey[FrameRoleKey(frame: item.frame, role: role)]
            let value: String? = {
                guard let raw = element.normalizedValue, !raw.isEmpty else { return nil }
                return raw
            }()
            entries.append(Outline.Entry(
                aliases: Outline.Aliases(at: index + 1, list: listAlias),
                role: role,
                label: rawLabel(for: element),
                frame: item.frame,
                region: region,
                states: stateTags(for: element),
                uniqueId: uniqueId,
                value: value,
                resourceId: nil,
                hint: nil,
                depth: item.collected.depth
            ))
        }

        let text = renderText(appLabel: appLabel, screen: screen, entries: entries, orientationTag: orientationTag)
        return Outline(text: text, entries: entries, lists: lists, screen: screen, appLabel: appLabel)
    }

    private struct FrameRoleKey: Hashable {
        public let frame: Outline.Frame
        public let role: String
    }

    // MARK: - Internal working types

    private struct Collected {
        public let element: AccessibilityElement
        public let declaredRegion: Outline.Region?
        public let depth: Int
    }

    private struct Rounded {
        public let collected: Collected
        public let frame: Outline.Frame
    }

    // MARK: - Tree walking

    private static func pickRoot(_ tree: [AccessibilityElement]) -> AccessibilityElement? {
        if let app = tree.first(where: { $0.type == "Application" }) {
            return app
        }
        return tree.first
    }

    private static func walk(
        element: AccessibilityElement,
        declaredRegion: Outline.Region?,
        depth: Int,
        collected: inout [Collected]
    ) {
        // A declared region is sticky: once we enter one, descendants
        // inherit it. Outer wins over inner per spec §3.1 — this keeps
        // the outline flat and avoids nested bracket confusion.
        let promoted = declaredRegion == nil ? regionIfDeclared(element) : nil
        let effectiveRegion = declaredRegion ?? promoted

        // Elements that are themselves the wrapper of a new declared
        // region are represented by the region header; listing them
        // again as an element would add a duplicate full-width line.
        // Nested declared-region wrappers (when we're already inside an
        // outer region) are kept as normal elements — they carry useful
        // label/frame information.
        if promoted == nil {
            collected.append(Collected(
                element: element,
                declaredRegion: effectiveRegion,
                depth: depth
            ))
        }

        for child in element.children ?? [] {
            walk(element: child, declaredRegion: effectiveRegion, depth: depth + 1, collected: &collected)
        }
    }

    private static func regionIfDeclared(_ element: AccessibilityElement) -> Outline.Region? {
        guard let type = element.type,
              let kind = declaredRegionKinds[type],
              let label = element.normalizedLabel,
              !label.isEmpty
        else {
            return nil
        }
        return Outline.Region(kind: kind, label: label)
    }

    // MARK: - Filter / round

    private static func roundAndFilter(inside screen: Outline.Frame) -> (Collected) -> Rounded? {
        return { collected in
            guard let frame = collected.element.frame else { return nil }
            guard frame.width > 0, frame.height > 0 else { return nil }

            let rounded = Outline.Frame(
                x: Int(frame.x.rounded()),
                y: Int(frame.y.rounded()),
                width: Int(frame.width.rounded()),
                height: Int(frame.height.rounded())
            )

            // Drop elements fully outside the app frame. Only reject if
            // there's a known screen size; the --point path can return a
            // subtree whose wrapper has no frame, and we'd rather show
            // those elements than filter everything out.
            if screen.width > 0, screen.height > 0 {
                if rounded.x + rounded.width <= 0 { return nil }
                if rounded.y + rounded.height <= 0 { return nil }
                if rounded.x >= screen.width { return nil }
                if rounded.y >= screen.height { return nil }
            }

            return Rounded(collected: collected, frame: rounded)
        }
    }

    // MARK: - Dedup

    /// When a wrapper (typically an `AXGroup`) and its single child share
    /// the same rounded frame and label, keep the deeper one. The child
    /// is the actionable leaf; the wrapper exists only because the app
    /// chose to expose a container for VoiceOver grouping.
    private static func deduplicate(_ items: [Rounded]) -> [Rounded] {
        struct Key: Hashable {
            public let role: String
            public let label: String
            public let frame: Outline.Frame
        }

        var bestIndexByKey: [Key: Int] = [:]
        for (index, item) in items.enumerated() {
            let key = Key(
                role: item.collected.element.type ?? "",
                label: item.collected.element.normalizedLabel ?? "",
                frame: item.frame
            )
            if let previous = bestIndexByKey[key] {
                if item.collected.depth > items[previous].collected.depth {
                    bestIndexByKey[key] = index
                }
            } else {
                bestIndexByKey[key] = index
            }
        }
        let survivors = Set(bestIndexByKey.values)

        var out: [Rounded] = []
        out.reserveCapacity(survivors.count)
        for (index, item) in items.enumerated() where survivors.contains(index) {
            out.append(item)
        }
        return out
    }

    // MARK: - Region assignment

    private static func yBandRegion(for frame: Outline.Frame, screenHeight: Int) -> Outline.Region {
        // When we have no screen height (subtree / --point), everything
        // collapses to `Content` rather than emitting a misleading band.
        guard screenHeight > 0 else {
            return Outline.Region(kind: "Content", label: nil)
        }
        let yCenter = frame.y + frame.height / 2
        if yCenter < yBandInset {
            return Outline.Region(kind: "Top", label: nil)
        }
        if yCenter >= screenHeight - yBandInset {
            return Outline.Region(kind: "Bottom", label: nil)
        }
        return Outline.Region(kind: "Content", label: nil)
    }

    // MARK: - Per-element rendering helpers

    private static func rawLabel(for element: AccessibilityElement) -> String {
        if let label = element.normalizedLabel, !label.isEmpty {
            return label
        }
        if let value = element.normalizedValue, !value.isEmpty {
            return value
        }
        return ""
    }

    private static func stateTags(for element: AccessibilityElement) -> [String] {
        var tags: [String] = []

        let isSelectable = element.type.map(selectableTypes.contains) ?? false
        let isSelected = isSelectable && element.normalizedValue == "1"
        if isSelected {
            tags.append("selected")
        }

        if element.enabled == false {
            tags.append("disabled")
        }

        if !isSelected,
           let type = element.type,
           valueBearingTypes.contains(type),
           let value = element.normalizedValue,
           !value.isEmpty
        {
            let rendered = escapeAndTruncate(value, maxGraphemes: 30)
            tags.append("value=\"\(rendered)\"")
        }

        return tags
    }

    // MARK: - Text rendering

    private struct RegionKey: Hashable {
        public let kind: String
        public let label: String?
    }

    private static func renderText(
        appLabel: String,
        screen: Outline.Frame,
        entries: [Outline.Entry],
        orientationTag: String? = nil
    ) -> String {
        var output = ""
        // Two header shapes: a real Application root carries its frame,
        // so we use the familiar "App: <label>  WxH" form. A --point
        // subtree has no screen context — we emit "Subtree: <label>"
        // without a dimension suffix that would only read as `0x0`.
        if screen.width > 0, screen.height > 0 {
            let suffix = orientationTag.map { "  (\($0))" } ?? ""
            output.append("App: \(appLabel)  \(screen.width)x\(screen.height)\(suffix)\n")
        } else {
            output.append("Subtree: \(appLabel)\n")
        }

        guard !entries.isEmpty else {
            return output
        }

        // Group by `(kind, label)` preserving first-appearance order so
        // regions naturally come out in visual (y, x) order — the
        // element sort already put them there.
        var order: [RegionKey] = []
        var members: [RegionKey: [Outline.Entry]] = [:]
        for entry in entries {
            let key = RegionKey(kind: entry.region.kind, label: entry.region.label)
            if members[key] == nil {
                order.append(key)
            }
            members[key, default: []].append(entry)
        }

        for key in order {
            output.append("\n")
            output.append(regionHeader(key, screenHeight: screen.height))
            output.append("\n")
            for entry in members[key] ?? [] {
                output.append(elementLine(entry))
                output.append("\n")
            }
        }

        return output
    }

    private static func regionHeader(_ key: RegionKey, screenHeight: Int) -> String {
        // Without a valid screen height (--point subtree) the y-band
        // numbers are meaningless, so we drop the `y=...` suffix and
        // just show the kind — this path only emits `Content` today
        // because that's the fallback yBandRegion picks when the screen
        // is zero.
        let hasScreen = screenHeight > 0
        switch key.kind {
        case "Top":
            return hasScreen ? "[Top  y<\(yBandInset)]" : "[Top]"
        case "Content":
            if hasScreen {
                let upperBound = max(yBandInset, screenHeight - yBandInset)
                return "[Content  y=\(yBandInset)..\(upperBound)]"
            }
            return "[Content]"
        case "Bottom":
            if hasScreen {
                return "[Bottom  y>=\(max(yBandInset, screenHeight - yBandInset))]"
            }
            return "[Bottom]"
        default:
            if let label = key.label {
                return "[\(key.kind)  \"\(escape(label))\"]"
            }
            return "[\(key.kind)]"
        }
    }

    private static func elementLine(_ entry: Outline.Entry) -> String {
        var prefix = "@\(entry.aliases.at)"
        if let list = entry.aliases.list {
            // Dominant list (scope=1) renders as bare `#N`; non-dominant
            // scopes render with the `@M` suffix to namespace them. See
            // DESCRIBE_UI_OUTLINE.md §2.2.
            if list.scope <= 1 {
                prefix += " #\(list.index)"
            } else {
                prefix += " #\(list.index)@\(list.scope)"
            }
        }
        let label = escapeAndTruncate(entry.label, maxGraphemes: 60)
        let frame = "(\(entry.frame.x),\(entry.frame.y) \(entry.frame.width)x\(entry.frame.height))"
        var line = "  \(prefix)  \(entry.role)  \"\(label)\""
        if let uniqueId = entry.uniqueId {
            // `#<id>` doubles as a selector users can paste back into
            // `sim-use tap`. AXUniqueId values observed in real trees are
            // dot/camelCase identifiers with no whitespace, so they sit
            // inline unquoted without ambiguity against the outline
            // grammar.
            line += "  #\(uniqueId)"
        }
        line += "  \(frame)"
        for tag in entry.states {
            line += "  \(tag)"
        }
        return line
    }

    // MARK: - String helpers

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Grapheme-aware truncation with a trailing `…` when the input
    /// exceeds the budget. Internal whitespace runs (CR/LF/TAB) collapse
    /// to single spaces so element lines stay on one line.
    public static func escapeAndTruncate(_ s: String, maxGraphemes: Int) -> String {
        let collapsed = collapseWhitespace(s)
        let escaped = escape(collapsed)

        let clusters = Array(escaped)
        guard clusters.count > maxGraphemes else {
            return escaped
        }
        let keep = max(0, maxGraphemes - 1)
        return String(clusters.prefix(keep)) + ellipsis
    }

    /// Delegates to the canonical collapse in SimUseCore — the same
    /// normal form the selector resolvers match on, so the outline
    /// display and the copy-back round-trip can never drift apart.
    /// This also folds whitespace the old scalar-map missed (NBSP,
    /// U+2028/U+2029 line separators), so element lines can no longer
    /// wrap on exotic line breaks.
    private static func collapseWhitespace(_ s: String) -> String {
        SelectorTextMatcher.collapseWhitespace(s)
    }
}