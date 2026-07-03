// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

public enum AccessibilityQuery {
    case id(String)
    case label(String)
    case value(String)
    case labelContains(String)
    case labelRegex(pattern: String)
}

public enum ElementResolutionError: LocalizedError, HintProviding {
    /// `candidateKind` labels the candidate list in the hint (e.g.
    /// "labels", "ids") so the user can see which attribute the
    /// listed strings actually represent. Defaults aren't supported
    /// on enum cases so call-sites pass "labels" explicitly for the
    /// common path. `suggestedAlternative`, when set, is woven into
    /// the human error message and the hint so an `--id` failure
    /// whose value matches a label can recommend `--label` directly.
    case notFound(
        kind: String,
        value: String,
        candidates: [String],
        candidateKind: String,
        suggestedAlternative: String?
    )
    case multipleMatches(count: Int, kind: String, value: String, hasUniqueIDs: Bool, candidates: [String])
    case invalidFrame(reason: String)
    case invalidPattern(kind: String, pattern: String, reason: String)

    public var errorDescription: String? {
        let tip = AccessibilityTargetResolver.describeUITip
        switch self {
        case .notFound(let kind, let value, _, _, let suggestedAlternative):
            // Confusion guard: agents reach for `--id <small-int>` thinking
            // it is the outline alias. `--id` matches AXUniqueId literally;
            // the positional `@N` is the outline alias. When the lookup
            // fails on a small integer, point them at the right syntax.
            // (Before second-round verification this branch checked
            // `kind == "id"` and never fired — callers pass the user-
            // facing `"--id"` flag spelling.)
            if kind == "--id", let aliasSuggestion = Self.outlineAliasSuggestion(for: value) {
                return "No accessibility element matched --id '\(value)'. Did you mean the positional alias `@\(aliasSuggestion)`? `--id` matches AXUniqueId/accessibilityIdentifier literally; `@N` selects the N-th `describe-ui` outline entry. \(tip)"
            }
            if let suggestedAlternative {
                return "No accessibility element matched \(kind) '\(value)'. \(suggestedAlternative) \(tip)"
            }
            return "No accessibility element matched \(kind) '\(value)'. \(tip)"
        case .multipleMatches(let count, let kind, let value, let hasUniqueIDs, _):
            if hasUniqueIDs {
                return "Multiple (\(count)) accessibility elements matched \(kind) '\(value)'. Use --id when labels are not unique. \(tip)"
            }
            return "Multiple (\(count)) accessibility elements matched \(kind) '\(value)', and none of the matches expose AXUniqueId on this screen. Use coordinates for this step (tap -x/-y) or target a more specific screen/state. \(tip)"
        case .invalidFrame(let reason):
            return "\(reason) \(tip)"
        case .invalidPattern(let kind, let pattern, let reason):
            return "\(kind) '\(pattern)' is not a valid pattern: \(reason)"
        }
    }

    public var isNotFound: Bool {
        if case .notFound = self { return true }
        return false
    }

    /// Structured supplementary info that surfaces in the `--json` error
    /// envelope. The human `errorDescription` already explains the failure;
    /// the hint exists so agents can self-correct without re-parsing prose.
    public var hint: String? {
        switch self {
        case .notFound(let kind, let value, let candidates, let candidateKind, let suggestedAlternative):
            let base = Self.formatHint(prefix: "pattern=\(kind) '\(value)'", label: candidateKind, labels: candidates)
            guard let suggestedAlternative else { return base }
            guard let base else { return suggestedAlternative }
            return "\(base); \(suggestedAlternative)"
        case .multipleMatches(_, let kind, let value, _, let candidates):
            return Self.formatHint(prefix: "pattern=\(kind) '\(value)'", label: "matches", labels: candidates)
        case .invalidFrame, .invalidPattern:
            return nil
        }
    }

    /// Returns the canonical decimal form of `value` iff it parses as a
    /// positive integer with no sign / whitespace / leading zeros and falls
    /// in the plausible outline-alias range (1..999). Anything else returns
    /// nil so the hint never fires on real-world AXUniqueId strings that
    /// happen to be numeric (e.g. `"0"`, `"0042"`, `"1234567"`).
    private static func outlineAliasSuggestion(for value: String) -> String? {
        guard let n = Int(value), n > 0, n < 1000 else { return nil }
        guard String(n) == value else { return nil }
        return String(n)
    }

    private static func formatHint(prefix: String, label: String, labels: [String]) -> String? {
        guard !labels.isEmpty else { return prefix }
        let cap = 10
        let total = labels.count
        let shown = Array(labels.prefix(cap))
        let rendered = shown.map { "'\($0)'" }.joined(separator: ", ")
        let countTag = total > cap ? "(top \(cap)/\(total))" : "(\(total))"
        return "\(prefix); \(label) \(countTag): \(rendered)"
    }
}

public struct AccessibilityTargetResolver {
    public static let describeUITip = "Make sure the app is on the expected screen, then run `sim-use describe-ui --udid <SIMULATOR_UDID>` and prefer --id when available."

    /// Cap on how many candidate labels are collected for the `notFound`
    /// hint. Big AX trees can carry hundreds of labelled nodes; truncating
    /// keeps the JSON envelope small while still letting agents see the
    /// space of available targets.
    private static let candidateCap = 32

    /// Geometric AND-filter applied alongside the type filter to narrow
    /// the candidate pool before selector matching. Each bound exists in
    /// two flavours: absolute pixel value, or relative 0…1 fraction of the
    /// screen frame (for device-size-independent rules like "bottom 30%").
    /// On the same axis bound (e.g. minY vs minYRel) abs and rel are
    /// mutually exclusive — `Tap.validate()` enforces this so the resolver
    /// never has to pick a winner.
    public struct FrameFilter {
        public var minX: Double? = nil
        public var maxX: Double? = nil
        public var minY: Double? = nil
        public var maxY: Double? = nil
        public var minXRel: Double? = nil
        public var maxXRel: Double? = nil
        public var minYRel: Double? = nil
        public var maxYRel: Double? = nil

        public init() {}

        public var isEmpty: Bool {
            minX == nil && maxX == nil && minY == nil && maxY == nil &&
            minXRel == nil && maxXRel == nil && minYRel == nil && maxYRel == nil
        }

        public var hasRelativeBounds: Bool {
            minXRel != nil || maxXRel != nil || minYRel != nil || maxYRel != nil
        }

        /// Resolve relative bounds against a concrete screen frame, returning
        /// an all-absolute filter ready for per-element checks.
        public func resolved(screen: AccessibilityElement.Frame) -> FrameFilter {
            var copy = self
            if let r = minXRel { copy.minX = screen.x + r * screen.width;  copy.minXRel = nil }
            if let r = maxXRel { copy.maxX = screen.x + r * screen.width;  copy.maxXRel = nil }
            if let r = minYRel { copy.minY = screen.y + r * screen.height; copy.minYRel = nil }
            if let r = maxYRel { copy.maxY = screen.y + r * screen.height; copy.maxYRel = nil }
            return copy
        }

        public func contains(_ frame: AccessibilityElement.Frame?) -> Bool {
            guard let frame else { return false }
            if let minX, frame.x < minX { return false }
            if let maxX, frame.x > maxX { return false }
            if let minY, frame.y < minY { return false }
            if let maxY, frame.y > maxY { return false }
            return true
        }

        public struct ParseError: Error {
            public let message: String
        }

        /// Parse one or more `--frame key=value[,key=value]` strings into a
        /// FrameFilter. Numeric values are absolute pixels; suffixing `r`
        /// marks the value as a 0…1 fraction of the screen frame.
        ///
        /// Same key set twice (across or within --frame flags) is an error.
        /// Mixing abs and rel on the same axis bound (e.g. `minY=700` plus
        /// `minY=0.6r`) is also an error — pick one form.
        public init(specs: [String]) throws {
            self.init()
            var seen: Set<String> = []
            for spec in specs {
                let pairs = spec.split(separator: ",", omittingEmptySubsequences: false)
                for raw in pairs {
                    let pair = raw.trimmingCharacters(in: .whitespaces)
                    guard !pair.isEmpty else {
                        throw ParseError(message: "--frame entry is empty (check for stray commas in '\(spec)').")
                    }
                    guard let eq = pair.firstIndex(of: "=") else {
                        throw ParseError(message: "--frame entry '\(pair)' must be 'key=value' (e.g. minY=700 or minY=0.6r).")
                    }
                    let key = String(pair[..<eq]).trimmingCharacters(in: .whitespaces)
                    let valueRaw = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    guard Self.knownKeys.contains(key) else {
                        throw ParseError(message: "--frame key '\(key)' is unknown. Valid keys: \(Self.knownKeys.sorted().joined(separator: ", ")).")
                    }
                    guard !seen.contains(key) else {
                        throw ParseError(message: "--frame key '\(key)' was specified more than once.")
                    }
                    seen.insert(key)
                    let (number, isRelative) = try Self.parseNumber(valueRaw, key: key)
                    if isRelative {
                        guard number >= 0, number <= 1 else {
                            throw ParseError(message: "--frame \(key)=\(valueRaw): relative value must be in 0…1.")
                        }
                    }
                    Self.assign(self: &self, key: key, value: number, relative: isRelative)
                }
            }
            if let lo = minX, let hi = maxX, lo > hi {
                throw ParseError(message: "--frame minX (\(lo)) must be ≤ maxX (\(hi)).")
            }
            if let lo = minY, let hi = maxY, lo > hi {
                throw ParseError(message: "--frame minY (\(lo)) must be ≤ maxY (\(hi)).")
            }
            if let lo = minXRel, let hi = maxXRel, lo > hi {
                throw ParseError(message: "--frame minX (\(lo)r) must be ≤ maxX (\(hi)r).")
            }
            if let lo = minYRel, let hi = maxYRel, lo > hi {
                throw ParseError(message: "--frame minY (\(lo)r) must be ≤ maxY (\(hi)r).")
            }
        }

        private static let knownKeys: Set<String> = ["minX", "maxX", "minY", "maxY"]

        private static func parseNumber(_ raw: String, key: String) throws -> (Double, Bool) {
            let isRelative = raw.hasSuffix("r")
            let numericPart = isRelative ? String(raw.dropLast()) : raw
            guard let value = Double(numericPart) else {
                throw ParseError(message: "--frame \(key)='\(raw)' is not a number (use e.g. 700 or 0.6r).")
            }
            return (value, isRelative)
        }

        private static func assign(self filter: inout FrameFilter, key: String, value: Double, relative: Bool) {
            switch (key, relative) {
            case ("minX", false): filter.minX = value
            case ("maxX", false): filter.maxX = value
            case ("minY", false): filter.minY = value
            case ("maxY", false): filter.maxY = value
            case ("minX", true):  filter.minXRel = value
            case ("maxX", true):  filter.maxXRel = value
            case ("minY", true):  filter.minYRel = value
            case ("maxY", true):  filter.maxYRel = value
            default: break // unreachable: key already validated against knownKeys
            }
        }
    }

    public static func resolveCenterPoint(
        roots: [AccessibilityElement],
        query: AccessibilityQuery,
        elementType: String? = nil,
        frameFilter: FrameFilter? = nil
    ) throws -> (x: Double, y: Double) {
        var allElements = roots.flatMap { $0.flattened() }

        if let elementType {
            allElements = allElements.filter { $0.type == elementType }
        }

        if let frameFilter, !frameFilter.isEmpty {
            let effective: FrameFilter
            if frameFilter.hasRelativeBounds {
                guard let screen = roots.first?.frame else {
                    throw ElementResolutionError.invalidFrame(reason: "--frame uses relative bounds but the AX root has no frame to resolve against.")
                }
                effective = frameFilter.resolved(screen: screen)
            } else {
                effective = frameFilter
            }
            allElements = allElements.filter { effective.contains($0.frame) }
        }

        let matchedElement = try matchElement(query: query, in: allElements)

        guard let frame = matchedElement.frame else {
            throw ElementResolutionError.invalidFrame(reason: "Matched element has no frame.")
        }
        guard frame.width > 0, frame.height > 0 else {
            throw ElementResolutionError.invalidFrame(reason: "Matched element has an invalid frame size (\(frame.width)x\(frame.height)).")
        }

        let centerX = frame.x + (frame.width / 2.0)
        let centerY = frame.y + (frame.height / 2.0)
        return (x: centerX, y: centerY)
    }

    private static func matchElement(
        query: AccessibilityQuery,
        in allElements: [AccessibilityElement]
    ) throws -> AccessibilityElement {
        switch query {
        case .id(let rawValue):
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = allElements.filter { $0.normalizedUniqueId == value }
            // For `--id`, show *ids* as candidates (the old code showed
            // labels, which led users to retry `--id <a-label>` after
            // seeing labels in the hint). When the raw value happens to
            // match a label on the tree we also recommend `--label`.
            if matches.isEmpty {
                let valueMatchesLabel = allElements.contains { $0.normalizedLabel == value }
                let valueMatchesValue = allElements.contains { $0.normalizedValue == value }
                let suggestion: String?
                if valueMatchesLabel {
                    suggestion = "Did you mean `--label '\(rawValue)'`? '\(rawValue)' matches an accessibility label on this screen, not an id."
                } else if valueMatchesValue {
                    suggestion = "Did you mean `--value '\(rawValue)'`? '\(rawValue)' matches an accessibility value on this screen, not an id."
                } else {
                    suggestion = nil
                }
                throw ElementResolutionError.notFound(
                    kind: "--id",
                    value: rawValue,
                    candidates: candidateIDs(for: allElements),
                    candidateKind: "ids",
                    suggestedAlternative: suggestion
                )
            }
            return try selectUniqueMatch(
                matches,
                kind: "--id",
                value: rawValue,
                candidates: candidateLabels(for: matches, fallback: allElements),
                candidateKind: "labels"
            )
        case .label(let rawValue):
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            var matches = allElements.filter { $0.normalizedLabel == value }
            if matches.isEmpty, let collapsedQuery = AccessibilityElement.collapseWhitespace(rawValue) {
                // Whitespace-tolerant fallback: a multi-line AXLabel renders
                // space-joined in the compact outline, so the exact query the
                // agent copies back never equals the newline-bearing label.
                // Only runs when the exact pass found nothing, so existing
                // exact matches are never altered.
                matches = allElements.filter { $0.collapsedLabel == collapsedQuery }
            }
            return try selectBestLabelMatch(
                matches,
                kind: "--label",
                value: rawValue,
                fallbackPool: allElements
            )
        case .value(let rawValue):
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            var matches = allElements.filter { $0.normalizedValue == value }
            if matches.isEmpty, let collapsedQuery = AccessibilityElement.collapseWhitespace(rawValue) {
                matches = allElements.filter { $0.collapsedValue == collapsedQuery }
            }
            return try selectBestLabelMatch(
                matches,
                kind: "--value",
                value: rawValue,
                fallbackPool: allElements
            )
        case .labelContains(let rawValue):
            let needle = rawValue
            var matches = allElements.filter { ($0.normalizedLabel ?? "").contains(needle) }
            if matches.isEmpty,
               let collapsedNeedle = AccessibilityElement.collapseWhitespace(rawValue),
               !collapsedNeedle.isEmpty {
                matches = allElements.filter { ($0.collapsedLabel ?? "").contains(collapsedNeedle) }
            }
            return try selectBestLabelMatch(
                matches,
                kind: "--label-contains",
                value: rawValue,
                fallbackPool: allElements
            )
        case .labelRegex(let pattern):
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern, options: [])
            } catch {
                throw ElementResolutionError.invalidPattern(
                    kind: "--label-regex",
                    pattern: pattern,
                    reason: error.localizedDescription
                )
            }
            let matches = allElements.filter { element in
                guard let label = element.normalizedLabel else { return false }
                let range = NSRange(label.startIndex..<label.endIndex, in: label)
                return regex.firstMatch(in: label, options: [], range: range) != nil
            }
            return try selectBestLabelMatch(
                matches,
                kind: "--label-regex",
                value: pattern,
                fallbackPool: allElements
            )
        }
    }

    private static func selectUniqueMatch(
        _ matches: [AccessibilityElement],
        kind: String,
        value: String,
        candidates: [String],
        candidateKind: String = "labels"
    ) throws -> AccessibilityElement {
        guard !matches.isEmpty else {
            throw ElementResolutionError.notFound(
                kind: kind,
                value: value,
                candidates: candidates,
                candidateKind: candidateKind,
                suggestedAlternative: nil
            )
        }
        guard matches.count == 1 else {
            let hasUniqueIDs = matches.contains {
                guard let id = $0.normalizedUniqueId else { return false }
                return !id.isEmpty
            }
            throw ElementResolutionError.multipleMatches(
                count: matches.count,
                kind: kind,
                value: value,
                hasUniqueIDs: hasUniqueIDs,
                candidates: candidateLabels(for: matches)
            )
        }
        return matches[0]
    }

    private static func selectBestLabelMatch(
        _ matches: [AccessibilityElement],
        kind: String,
        value: String,
        fallbackPool: [AccessibilityElement]
    ) throws -> AccessibilityElement {
        let actionableMatches = matches.filter(\.isActionable)
        if actionableMatches.count == 1 {
            return actionableMatches[0]
        }

        if actionableMatches.count > 1 {
            return try selectUniqueMatch(
                actionableMatches,
                kind: kind,
                value: value,
                candidates: candidateLabels(for: actionableMatches)
            )
        }

        return try selectUniqueMatch(
            matches,
            kind: kind,
            value: value,
            candidates: candidateLabels(for: matches, fallback: fallbackPool)
        )
    }

    /// Pull a de-duplicated, capped list of `AXLabel` strings to surface in
    /// the error hint. When `pool` (the matched set) is empty we sample
    /// from `fallback` (the post-element-type tree) so `notFound` still
    /// shows what is reachable on screen.
    private static func candidateLabels(
        for pool: [AccessibilityElement],
        fallback: [AccessibilityElement] = []
    ) -> [String] {
        let source = pool.isEmpty ? fallback : pool
        var seen = Set<String>()
        var ordered: [String] = []
        for element in source {
            guard let label = element.normalizedLabel, !label.isEmpty else { continue }
            if seen.insert(label).inserted {
                ordered.append(label)
                if ordered.count >= candidateCap { break }
            }
        }
        return ordered
    }

    /// Same shape as `candidateLabels` but pulls `AXUniqueId`s — used
    /// for `--id` not-found hints so the candidate list reflects what
    /// `--id` actually matches against.
    private static func candidateIDs(for pool: [AccessibilityElement]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for element in pool {
            guard let id = element.normalizedUniqueId, !id.isEmpty else { continue }
            if seen.insert(id).inserted {
                ordered.append(id)
                if ordered.count >= candidateCap { break }
            }
        }
        return ordered
    }
}
