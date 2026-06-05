// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Maps an Android `ElementNode` to the cross-platform role / region
/// vocabulary used by the outline format and selector pipeline.
///
/// Role rules (best match wins):
///   1. Canonical vocabulary hit on `className` (e.g. EditText → TextField).
///   2. Last segment of `className` when no vocabulary entry matches —
///      e.g. `com.example.app.common.view.SomeWidget` → `SomeWidget`.
///   3. `"Element"` fallback when className is empty.
public enum AndroidClassifier {

    /// Container className → declared-region short name. Mirrors iOS
    /// `OutlineFormatter.declaredRegionKinds`.
    public static let declaredRegionByClass: [String: String] = [
        "androidx.appcompat.widget.Toolbar": "NavBar",
        "com.google.android.material.appbar.MaterialToolbar": "NavBar",
        "android.widget.Toolbar": "NavBar",
        "com.google.android.material.bottomnavigation.BottomNavigationView": "TabBar",
        "com.google.android.material.appbar.AppBarLayout": "NavBar",
        "androidx.recyclerview.widget.RecyclerView": "List",
        "android.widget.ListView": "List",
        "android.widget.GridView": "List",
        "android.widget.ScrollView": "Scroll",
        "androidx.core.widget.NestedScrollView": "Scroll",
    ]

    /// Roles whose value (Android `text`) should surface as a `value=…`
    /// state tag (mirrors iOS's `valueBearingTypes`).
    ///
    /// `Switch` is included for parity with iOS — vendor-skinned
    /// Settings apps and custom subclasses occasionally set distinct
    /// `textOn` / `textOff` strings, so a Switch whose `text` differs
    /// from its label carries useful semantic information beyond the
    /// binary `selected`/`unchecked` tag. The common case where
    /// `text == label` is suppressed by `effectiveValue`, so no
    /// double-printing.
    public static let valueBearingRoles: Set<String> = [
        "TextField",
        "Switch",
    ]

    /// Roles whose `selected` flag surfaces as a `selected` tag.
    ///
    /// `Toggle` is a synthesized role we attach to bare `android.view.View`
    /// nodes that carry `checkable=true` — the shape Jetpack Compose
    /// produces when a `Modifier.toggleable(...)` row hosts a `Switch()`
    /// child. The toggle state lives on the outer row, the inner switch
    /// is rendered as a label-less, non-interactive View. Calling that
    /// outer row "Toggle" surfaces the binary semantic without
    /// pretending it's an `android.widget.Switch`.
    public static let selectableRoles: Set<String> = [
        "Switch", "Checkbox", "Toggle",
    ]

    public static func role(for node: ElementNode) -> String {
        if let canonical = ElementVocabulary.canonicalForAndroidClass(node.className) {
            return canonical
        }
        // Bare View / ViewGroup with `checkable=true` is the Compose-
        // toggleable-row shape. Without this branch the outline shows
        // `View "" checked` which doesn't tell the agent it's a binary
        // toggle, and the OFF case (no `checked` tag) is indistinguishable
        // from a regular tappable row.
        if node.checkable {
            return "Toggle"
        }
        return Self.shortClass(node.className)
    }

    public static func shortClass(_ className: String) -> String {
        if className.isEmpty { return "Element" }
        if let dot = className.lastIndex(of: ".") {
            return String(className[className.index(after: dot)...])
        }
        return className
    }

    public static func declaredRegion(for node: ElementNode) -> Outline.Region? {
        guard let kind = declaredRegionByClass[node.className] else { return nil }
        // A region is meaningful when the container itself carries a
        // label OR when it's a navigation-shaped container that's almost
        // always region-like (TabBar/NavBar). For pure scroll views and
        // raw lists we require a label to avoid flooding the outline
        // with `[Scroll]` headers.
        let label = node.contentDescription.isEmpty ? node.text : node.contentDescription
        if kind == "TabBar" || kind == "NavBar" {
            return Outline.Region(kind: kind, label: label.isEmpty ? nil : label)
        }
        if label.isEmpty { return nil }
        return Outline.Region(kind: kind, label: label)
    }

    /// State tags. Mirrors iOS conventions: lowercase tokens, plus a
    /// `value="…"` tag when the node carries text distinct from its
    /// label.
    public static func stateTags(role: String, node: ElementNode, label: String) -> [String] {
        var tags: [String] = []

        if node.enabled == false {
            tags.append("disabled")
        }
        if node.selected {
            tags.append("selected")
        } else if selectableRoles.contains(role) && node.checked {
            tags.append("selected")
        }
        if node.checked && !tags.contains("selected") {
            tags.append("checked")
        }
        // Explicit OFF state for binary toggle widgets. Without this,
        // an unchecked Switch / Checkbox / Compose Toggle row carries
        // no state tag at all, making it visually indistinguishable
        // from a plain drill-down row that happens to be label-less.
        // Only fires when the node actually advertises the toggle
        // axis (`checkable=true`) — non-checkable selectableRole
        // entries (rare, but possible) still skip this.
        if selectableRoles.contains(role), node.checkable, !node.checked, !node.selected {
            tags.append("unchecked")
        }
        if node.focused {
            tags.append("focused")
        }
        if node.password {
            tags.append("password")
        }
        if valueBearingRoles.contains(role) {
            let value = effectiveValue(node: node, label: label) ?? ""
            if !value.isEmpty {
                let rendered = TruncationHelpers.escapeAndTruncate(value, maxGraphemes: 30)
                tags.append("value=\"\(rendered)\"")
            }
        }
        return tags
    }

    /// Returns the `text` field as a "value" only when it differs from
    /// the label (so we don't double-print). Returns nil when the text
    /// is the hint placeholder (per wire spec, the hint can leak into
    /// `text` on some Android versions; `hintText` is the disambiguator).
    public static func effectiveValue(node: ElementNode, label: String) -> String? {
        if node.text.isEmpty { return nil }
        if node.text == label { return nil }
        if let hint = node.hintText, hint == node.text {
            // The platform reported the hint as text on an empty input —
            // surface nothing for value so callers don't mistake it for
            // user-entered data.
            return nil
        }
        return node.text
    }
}