// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Cross-platform selector flags, Android-side resolution.
///
/// Same-field flags are mutually exclusive at the parser layer (`--label`
/// vs `--label-contains` vs `--label-regex`). Different-field flags
/// AND-combine for disambiguation (per C7). The Android pipeline mirrors
/// the iOS pipeline in shape so cross-platform skills don't need to
/// branch on platform when constructing a selector.
public struct AndroidSelector: Sendable, Equatable {
    public var id: String?
    public var label: String?
    public var labelContains: String?
    public var labelRegex: String?
    public var value: String?
    public var valueContains: String?
    public var valueRegex: String?
    public var elementType: String?
    /// Geometric AND-filter, parsed from one or more `--frame
    /// key=value[,key=value]` flags. Combined with text selectors to
    /// disambiguate when several entries share a label / value but
    /// live in different screen regions (e.g. the same "Save" button
    /// appearing on both a settings row and a confirmation dialog).
    /// `nil` skips the geometric narrow.
    public var frame: SelectorFrameFilter?

    public init(
        id: String? = nil,
        label: String? = nil,
        labelContains: String? = nil,
        labelRegex: String? = nil,
        value: String? = nil,
        valueContains: String? = nil,
        valueRegex: String? = nil,
        elementType: String? = nil,
        frame: SelectorFrameFilter? = nil
    ) {
        self.id = id
        self.label = label
        self.labelContains = labelContains
        self.labelRegex = labelRegex
        self.value = value
        self.valueContains = valueContains
        self.valueRegex = valueRegex
        self.elementType = elementType
        self.frame = frame
    }

    public var isEmpty: Bool {
        id == nil && label == nil && labelContains == nil && labelRegex == nil
            && value == nil && valueContains == nil && valueRegex == nil
            && elementType == nil
            && (frame?.isEmpty ?? true)
    }
}

public enum AndroidSelectorError: Error, LocalizedError, HintProviding, Equatable {
    /// `candidates` lists strings the user could have selected instead
    /// (sampled from what's on screen). `candidateKind` labels them in
    /// the hint ("labels" / "ids" / "values"). `suggestedAlternative`,
    /// when set, is woven into the human message — used when the failed
    /// value happens to match a different attribute kind, mirroring the
    /// iOS `notFound(suggestedAlternative:)` pattern.
    case noMatch(
        selector: AndroidSelector,
        candidates: [String],
        candidateKind: String,
        suggestedAlternative: String?
    )
    /// `matches` is a list of pre-rendered match descriptors (role +
    /// label + disambiguating attribute + frame) so an agent can pick
    /// which one to keep and what extra flag to AND in. Mirrors iOS's
    /// `multipleMatches(_:_:_:_:candidates:)`.
    case ambiguous(selector: AndroidSelector, count: Int, matches: [String])
    case empty
    case invalidRegex(pattern: String)

    public var errorDescription: String? {
        switch self {
        case .noMatch(let selector, _, _, let suggestedAlternative):
            // Confusion guard mirroring iOS: `tap --id 42` is the classic
            // first-time mistake — `--id` matches AXUniqueId/resource-id
            // literally, but agents reach for it thinking it is the outline
            // alias. Re-point at `@N` whenever `id` is set and the value
            // looks like a small positive integer, regardless of which
            // other selector flags accompany it. iOS's
            // `AccessibilityTargetResolver.swift:25` fires the hint
            // solely on `kind == "--id"` + small-int parse; an Android
            // combo like `tap --id 5 --element-type Button` is the
            // same confused-with-alias intent and deserves the same
            // hint.
            if let id = selector.id,
               let alias = Self.outlineAliasSuggestion(for: id)
            {
                return "No matching element found for selector --id '\(id)'. Did you mean the positional alias `@\(alias)`? `--id` matches AXUniqueId/resource-id literally; `@N` selects the N-th `describe-ui` outline entry."
            }
            // Compose: <head> [<suggestion>] [tip about new selector]
            var msg = "No matching element found for selector"
            if let kind = Self.primarySelectorLabel(selector) {
                msg += " \(kind)"
            }
            msg += "."
            if let suggestedAlternative {
                msg += " \(suggestedAlternative)"
            }
            return msg
        case .ambiguous(let selector, let count, _):
            // Mention the selector flag so agents can tell from the
            // text which constraint was the source of ambiguity. Then
            // recommend the standard disambiguators — `--id` is the
            // most reliable, then `--element-type`, then `--frame`.
            var msg = "Selector matched \(count) elements"
            if let kind = Self.primarySelectorLabel(selector) {
                msg += " for \(kind)"
            }
            // The bracketed hints below are tooling, not prose, so we
            // omit them when the caller already constrains by `--id`
            // (further `--id` doesn't exist) or by `--element-type`
            // (no second element-type can narrow further).
            var suggestions: [String] = []
            if selector.id == nil {
                suggestions.append("--id")
            }
            if selector.elementType == nil {
                suggestions.append("--element-type")
            }
            if selector.frame == nil {
                suggestions.append("--frame")
            }
            if suggestions.isEmpty {
                msg += "; the constraint set is already maximal — pick by coordinate or change the screen state."
            } else {
                msg += "; add \(suggestions.joined(separator: " / ")) to disambiguate."
            }
            return msg
        case .empty:
            return "Selector has no fields set."
        case .invalidRegex(let pattern):
            return "Invalid regex pattern: \(pattern)"
        }
    }

    /// Structured supplementary info that surfaces in the `--json` error
    /// envelope. The human `errorDescription` already explains the failure
    /// in prose; the hint exists so agents can self-correct without
    /// re-parsing it. Mirrors iOS's `ElementResolutionError.hint`.
    public var hint: String? {
        switch self {
        case .noMatch(let selector, let candidates, let candidateKind, let suggestedAlternative):
            let pattern = Self.primarySelectorLabel(selector) ?? "selector"
            let base = Self.formatHint(prefix: "pattern=\(pattern)", label: candidateKind, values: candidates)
            guard let suggestedAlternative else { return base }
            guard let base else { return suggestedAlternative }
            return "\(base); \(suggestedAlternative)"
        case .ambiguous(let selector, _, let matches):
            let pattern = Self.primarySelectorLabel(selector) ?? "selector"
            return Self.formatHint(prefix: "pattern=\(pattern)", label: "matches", values: matches)
        case .empty, .invalidRegex:
            return nil
        }
    }

    /// Returns the canonical decimal form of `value` iff it parses as a
    /// positive integer in the plausible outline-alias range (1..999) with
    /// no leading zeros — so the hint never fires on real numeric IDs like
    /// `"0"`, `"0042"`, or `"1234567"`. Mirrors the iOS helper in
    /// `AccessibilityTargetResolver.swift`.
    private static func outlineAliasSuggestion(for value: String) -> String? {
        guard let n = Int(value), n > 0, n < 1000 else { return nil }
        guard String(n) == value else { return nil }
        return String(n)
    }

    /// Render the primary selector flag and its argument as a flat
    /// string like `--label 'Settings'`. When the user passed multiple
    /// selectors, the priority follows the same order as the resolver
    /// (id → label → value → elementType) so the message names the
    /// constraint most likely to be the source of the failure.
    private static func primarySelectorLabel(_ selector: AndroidSelector) -> String? {
        if let v = selector.id { return "--id '\(v)'" }
        if let v = selector.label { return "--label '\(v)'" }
        if let v = selector.labelContains { return "--label-contains '\(v)'" }
        if let v = selector.labelRegex { return "--label-regex '\(v)'" }
        if let v = selector.value { return "--value '\(v)'" }
        if let v = selector.valueContains { return "--value-contains '\(v)'" }
        if let v = selector.valueRegex { return "--value-regex '\(v)'" }
        if let v = selector.elementType { return "--element-type '\(v)'" }
        return nil
    }

    /// Identical layout to iOS's `formatHint` for cross-platform
    /// agent parsing: `pattern=… ; <label> (<count>): 'a', 'b', …` or
    /// `(top N/M)` when truncated.
    private static func formatHint(prefix: String, label: String, values: [String]) -> String? {
        guard !values.isEmpty else { return prefix }
        let cap = 10
        let total = values.count
        let shown = Array(values.prefix(cap))
        let rendered = shown.map { "'\($0)'" }.joined(separator: ", ")
        let countTag = total > cap ? "(top \(cap)/\(total))" : "(\(total))"
        return "\(prefix); \(label) \(countTag): \(rendered)"
    }

    // MARK: - Equatable
    //
    // Hand-rolled because the previous synthesized impl excluded the new
    // hint payloads from compile-time tracking, and tests pattern-match
    // these cases without binding every associated value.
    public static func == (lhs: AndroidSelectorError, rhs: AndroidSelectorError) -> Bool {
        switch (lhs, rhs) {
        case (.noMatch(let lSel, let lCands, let lKind, let lAlt),
              .noMatch(let rSel, let rCands, let rKind, let rAlt)):
            return lSel == rSel && lCands == rCands && lKind == rKind && lAlt == rAlt
        case (.ambiguous(let lSel, let lCount, let lMatches),
              .ambiguous(let rSel, let rCount, let rMatches)):
            return lSel == rSel && lCount == rCount && lMatches == rMatches
        case (.empty, .empty):
            return true
        case (.invalidRegex(let lP), .invalidRegex(let rP)):
            return lP == rP
        default:
            return false
        }
    }
}

public enum AndroidSelectorResolver {

    /// Outline roles we treat as interactive when narrowing an ambiguous
    /// match set. Mirrors iOS's `AccessibilityElement.actionableTypes`
    /// projected onto the Android-side role vocabulary emitted by
    /// `AndroidClassifier.role(for:)` plus the click-fold rule in
    /// `AndroidOutlineRenderer` that promotes clickable wrappers to
    /// `"Button"`. iOS-specific roles that do not exist on Android
    /// (Cell, Link, MenuItem, PopUpButton, RadioButton, SegmentedControl,
    /// Tab, TabBarButton) are intentionally retained — keeping the set
    /// identical makes the cross-platform tap-resolution mental model
    /// uniform; the absent roles simply never match Android candidates.
    static let actionableRoles: Set<String> = [
        "Button",
        "Cell",
        "Checkbox",
        "Link",
        "MenuItem",
        "PopUpButton",
        "RadioButton",
        "SecureTextField",
        "SegmentedControl",
        "Switch",
        "Tab",
        "TabBarButton",
        "TextField",
        "Toggle",
    ]

    /// Resolution priority per plan W2.8:
    ///   1. `uniqueId` exact (highest stability)
    ///   2. `resource_id` short-name exact
    ///   3. `value` (text) match
    ///   4. `label` (contentDescription) match
    ///
    /// Substring text matching (`--label-contains` / `--value-contains`)
    /// restricts to clickable-ancestor candidates so it doesn't bind to
    /// the body paragraph that merely *mentions* a button word.
    ///
    /// Ambiguity handling mirrors iOS's `selectBestLabelMatch`: when the
    /// full candidate set has >1 match, we re-filter to entries with an
    /// `actionableRoles` role. If exactly one survives the filter we
    /// return it; otherwise the original ambiguity error is raised so
    /// the caller can disambiguate with `--id` / `--element-type` /
    /// `--frame`. This makes `--label "Notifications"` land on the
    /// `Button` row instead of an adjacent section-title `TextView`
    /// when both share the same label.
    ///
    /// AND-combines across different fields. Returns one entry or raises.
    public static func resolve(
        selector: AndroidSelector,
        entries: [Outline.Entry],
        screen: Outline.Frame? = nil,
        nodes: [ElementNode]? = nil
    ) throws -> Outline.Entry {
        if selector.isEmpty { throw AndroidSelectorError.empty }

        // Geometric narrow: resolve relative bounds against `screen`
        // before per-entry checks. If the caller didn't supply a
        // screen and the filter contains relative bounds, we cannot
        // resolve those and the filter is effectively a no-op for
        // the relative axes. Absolute bounds still apply.
        let resolvedFrame: SelectorFrameFilter?
        if let f = selector.frame, !f.isEmpty {
            if let screen, f.hasRelativeBounds {
                resolvedFrame = f.resolved(screen: screen)
            } else {
                resolvedFrame = f
            }
        } else {
            resolvedFrame = nil
        }

        // Actionable-narrowing is a "you meant the interactive one,
        // right?" hint that's only sensible when the user already
        // expressed intent via a label / value selector. `--id` is a
        // stability contract — collisions there are the user's data
        // issue, and silently picking the actionable winner masks
        // it. Same logic as iOS's `AccessibilityTargetResolver`:
        // only `selectBestLabelMatch` narrows, `selectUniqueMatch`
        // (the `--id` path) does not.
        let labelOrValueProvided =
            selector.label != nil
            || selector.labelContains != nil
            || selector.labelRegex != nil
            || selector.value != nil
            || selector.valueContains != nil
            || selector.valueRegex != nil

        var candidates = entries

        if let id = selector.id {
            // Honour the documented resolution priority (see the
            // doc-comment on `resolve(selector:)`): `uniqueId` is the
            // developer-set, higher-stability identifier, so a
            // `uniqueId` exact-match dominates the `resourceId`
            // namespace. Only fall back to matching against
            // `resourceId` when no entry's `uniqueId` matched —
            // otherwise a collision (same string used as both forms
            // across different entries) would silently bind through
            // whichever survived actionable-narrowing later.
            let uidHits = candidates.filter { $0.uniqueId == id }
            if !uidHits.isEmpty {
                candidates = uidHits
            } else {
                candidates = candidates.filter { $0.resourceId == id }
            }
        }

        if let label = selector.label {
            candidates = candidates.filter { $0.label == label }
        }
        if let needle = selector.labelContains {
            // Case-sensitive substring, mirroring iOS (`--label-contains`
            // is documented as case-sensitive on both sides). Earlier
            // releases used `localizedCaseInsensitiveContains` here,
            // which silently widened matches and diverged from iOS — a
            // selector that resolved to one element on iOS could
            // resolve to several on Android. Callers that want
            // case-insensitive matching should pass a `(?i)` regex via
            // `--label-regex`.
            candidates = candidates.filter { $0.label.contains(needle) }
        }
        if let pattern = selector.labelRegex {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                throw AndroidSelectorError.invalidRegex(pattern: pattern)
            }
            candidates = candidates.filter { entry in
                let range = NSRange(entry.label.startIndex..., in: entry.label)
                return regex.firstMatch(in: entry.label, options: [], range: range) != nil
            }
        }
        if let value = selector.value {
            candidates = candidates.filter { ($0.value ?? "") == value }
        }
        if let needle = selector.valueContains {
            // Case-sensitive — see the matching rationale on
            // `labelContains` above.
            candidates = candidates.filter { ($0.value ?? "").contains(needle) }
        }
        if let pattern = selector.valueRegex {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                throw AndroidSelectorError.invalidRegex(pattern: pattern)
            }
            candidates = candidates.filter { entry in
                let text = entry.value ?? ""
                let range = NSRange(text.startIndex..., in: text)
                return regex.firstMatch(in: text, options: [], range: range) != nil
            }
        }
        if let canonical = selector.elementType {
            candidates = candidates.filter { $0.role == canonical }
        }
        if let frameFilter = resolvedFrame {
            candidates = candidates.filter { frameFilter.contains($0.frame) }
        }

        guard !candidates.isEmpty else {
            throw noMatchError(selector: selector, pool: entries)
        }
        if candidates.count == 1 { return candidates[0] }

        // Multi-match. Narrow to the interactive subset only when the
        // user expressed label/value intent — see the comment at the
        // top of this function for the rationale. If zero or multiple
        // actionable entries remain we fall through to the original
        // ambiguity error so the caller adds disambiguation rather
        // than silently picking one.
        if labelOrValueProvided {
            let actionable = candidates.filter { actionableRoles.contains($0.role) }
            if actionable.count == 1 { return actionable[0] }
        }

        throw AndroidSelectorError.ambiguous(
            selector: selector,
            count: candidates.count,
            matches: formatMatches(candidates)
        )
    }

    /// Build the noMatch error with selector-aware candidate hints.
    /// `pool` is the full pre-filter entry list — we sample from it
    /// because the post-filter `candidates` array is empty by
    /// definition. The hint surfaces the attribute set the caller is
    /// least likely to know off-hand (ids when they searched by label;
    /// labels when they searched by id) plus a `suggestedAlternative`
    /// note when the failed value also exists under a different
    /// attribute kind on screen — same fix-it shape as iOS's
    /// `notFound(suggestedAlternative:)` for `--id` failures whose
    /// value happens to match a label.
    private static func noMatchError(
        selector: AndroidSelector,
        pool: [Outline.Entry]
    ) -> AndroidSelectorError {
        // --id failure: surface available ids, and recommend --label /
        // --value if the failed id string actually matches one of
        // those attributes on screen. Mirrors iOS C7.5.
        if let value = selector.id {
            let valueMatchesLabel = pool.contains { $0.label == value }
            let valueMatchesValue = pool.contains { ($0.value ?? "") == value }
            let suggestion: String?
            if valueMatchesLabel {
                suggestion = "Did you mean `--label '\(value)'`? '\(value)' matches an accessibility label on this screen, not an id."
            } else if valueMatchesValue {
                suggestion = "Did you mean `--value '\(value)'`? '\(value)' matches an accessibility value on this screen, not an id."
            } else {
                suggestion = nil
            }
            return .noMatch(
                selector: selector,
                candidates: collectIDs(from: pool),
                candidateKind: "ids",
                suggestedAlternative: suggestion
            )
        }
        // --value variants: list values on screen.
        if selector.value != nil || selector.valueContains != nil || selector.valueRegex != nil {
            return .noMatch(
                selector: selector,
                candidates: collectValues(from: pool),
                candidateKind: "values",
                suggestedAlternative: nil
            )
        }
        // Default (label / label-contains / label-regex / element-type
        // / frame-only): list labels on screen — that's the attribute
        // most likely to disambiguate a typo against the visible UI.
        return .noMatch(
            selector: selector,
            candidates: collectLabels(from: pool),
            candidateKind: "labels",
            suggestedAlternative: nil
        )
    }

    /// Cap on how many candidate strings reach the hint. Big screens
    /// can carry hundreds of labelled nodes; truncating keeps the JSON
    /// envelope small while still letting agents see the space of
    /// available targets. Matches iOS's `candidateCap`.
    private static let candidateCap = 32

    private static func collectLabels(from pool: [Outline.Entry]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in pool {
            let label = entry.label
            guard !label.isEmpty else { continue }
            if seen.insert(label).inserted {
                ordered.append(label)
                if ordered.count >= candidateCap { break }
            }
        }
        return ordered
    }

    private static func collectIDs(from pool: [Outline.Entry]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in pool {
            // Prefer uniqueId when present; otherwise resourceId. Both
            // strings travel under `--id`'s resolution path, so either
            // is a valid retry value for the agent.
            let id = entry.uniqueId ?? entry.resourceId ?? ""
            guard !id.isEmpty else { continue }
            if seen.insert(id).inserted {
                ordered.append(id)
                if ordered.count >= candidateCap { break }
            }
        }
        return ordered
    }

    private static func collectValues(from pool: [Outline.Entry]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in pool {
            guard let value = entry.value, !value.isEmpty else { continue }
            if seen.insert(value).inserted {
                ordered.append(value)
                if ordered.count >= candidateCap { break }
            }
        }
        return ordered
    }

    /// Compact one-line match descriptors for the ambiguous-error hint.
    /// Each line surfaces the role + label + the most useful disambiguating
    /// attribute (id when present, otherwise frame position) so an agent
    /// can pick which match it actually wanted and add the right extra
    /// flag.
    private static func formatMatches(_ entries: [Outline.Entry]) -> [String] {
        entries.prefix(candidateCap).map { entry in
            var parts: [String] = ["\(entry.role)"]
            if !entry.label.isEmpty {
                parts.append("'\(entry.label)'")
            }
            if let id = entry.uniqueId, !id.isEmpty {
                parts.append("#\(id)")
            } else if let rid = entry.resourceId, !rid.isEmpty {
                parts.append("#\(rid)")
            }
            let f = entry.frame
            parts.append("@(\(Int(f.x)),\(Int(f.y)))")
            return parts.joined(separator: " ")
        }
    }
}