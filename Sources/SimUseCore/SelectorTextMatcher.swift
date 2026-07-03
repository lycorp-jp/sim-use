// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Canonical whitespace normalization and the exact-first /
/// collapsed-fallback matching policy shared by every text selector
/// surface: the iOS `AccessibilityTargetResolver`, the Android
/// `AndroidSelectorResolver`, and both platforms' outline renderers.
///
/// The outline renders a multi-line label whitespace-collapsed so the
/// element line stays on one line; an agent then copies that collapsed
/// string back into `--label`/`--value`/`--label-contains`. Because the
/// renderers and the resolvers all normalize through this ONE
/// implementation, the copy-back round-trip holds by construction —
/// there is no second collapse definition to drift from.
///
/// Known limitation: the outline additionally escapes quotes/backslashes
/// and truncates long labels (60 graphemes, values 30) with a trailing
/// `…`. Those transforms are not invertible, so the round-trip only
/// holds for labels the outline renders untruncated and unescaped;
/// longer labels need the `@N` outline alias or `describe-ui --json`
/// (which carries raw labels).
public enum SelectorTextMatcher {
    /// Collapse every run of Unicode whitespace (spaces, tabs, newlines,
    /// NBSP, line/paragraph separators, ideographic space, …) to a single
    /// ASCII space and trim the ends. An all-whitespace string collapses
    /// to `""`. `Character.isWhitespace` follows the Unicode White_Space
    /// property; the `\r\n` grapheme is a single whitespace Character, so
    /// CRLF folds correctly without scalar-level iteration.
    public static func collapseWhitespace(_ string: String) -> String {
        string.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Optional-passthrough overload: nil in, nil out.
    public static func collapseWhitespace(_ string: String?) -> String? {
        string.map(collapseWhitespace)
    }

    /// Exact-first equality matching with a whitespace-collapsed
    /// fallback. The exact pass compares end-trimmed text against the
    /// end-trimmed query; only when it matches NOTHING does the fallback
    /// re-filter on the collapsed forms, so existing exact matches are
    /// never altered. An element with nil text never matches. An
    /// all-whitespace query is inert in the fallback: its collapsed form
    /// `""` only equals the collapsed form of all-whitespace text, which
    /// the exact pass already matched.
    public static func filterEquals<T>(
        _ items: [T],
        query: String,
        text: (T) -> String?
    ) -> [T] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = items.filter {
            text($0)?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuery
        }
        if !exact.isEmpty { return exact }
        let collapsedQuery = collapseWhitespace(query)
        return items.filter { collapseWhitespace(text($0)) == collapsedQuery }
    }

    /// Exact-first substring matching with a whitespace-collapsed
    /// fallback. The exact pass runs the raw needle against end-trimmed
    /// text. The fallback requires a non-empty collapsed needle —
    /// `"".contains` is universally true, so an all-whitespace needle
    /// must stay not-found rather than match everything.
    public static func filterContains<T>(
        _ items: [T],
        needle: String,
        text: (T) -> String?
    ) -> [T] {
        let exact = items.filter {
            (text($0)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").contains(needle)
        }
        if !exact.isEmpty { return exact }
        let collapsedNeedle = collapseWhitespace(needle)
        guard !collapsedNeedle.isEmpty else { return exact }
        return items.filter {
            (collapseWhitespace(text($0)) ?? "").contains(collapsedNeedle)
        }
    }
}
