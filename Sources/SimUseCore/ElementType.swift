// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Cross-platform element-type vocabulary used by `--element-type`.
/// One canonical name maps to:
///   - iOS: a set of `XCUIElementType` raw strings (matched on `Entry.role`)
///   - Android: a set of className substrings (matched on the wire
///     `ElementNode.className`)
/// See C6 in `plan/2026-05-12-Android-version-plan.md`.
public struct ElementTypeMapping: Sendable, Equatable {
    public let canonical: String
    public let iosRoles: [String]
    public let androidClassMatchers: [String]

    public init(canonical: String, iosRoles: [String], androidClassMatchers: [String]) {
        self.canonical = canonical
        self.iosRoles = iosRoles
        self.androidClassMatchers = androidClassMatchers
    }
}

public enum ElementVocabulary {
    /// Hard-coded vocabulary. ~13 entries × 2 platforms. Treat as living
    /// data: vocabulary additions ship in Swift releases and do NOT
    /// require a bridge `protocol_version` bump.
    public static let mappings: [ElementTypeMapping] = [
        .init(
            canonical: "Button",
            iosRoles: ["Button"],
            androidClassMatchers: [
                "android.widget.Button",
                "android.widget.ImageButton",
                "androidx.appcompat.widget.AppCompatButton",
                "androidx.appcompat.widget.AppCompatImageButton",
                "com.google.android.material.button.MaterialButton",
                "com.google.android.material.floatingactionbutton.FloatingActionButton",
            ]
        ),
        .init(
            canonical: "TextField",
            iosRoles: ["TextField", "SecureTextField"],
            androidClassMatchers: [
                "android.widget.EditText",
                "androidx.appcompat.widget.AppCompatEditText",
                "com.google.android.material.textfield.TextInputEditText",
            ]
        ),
        .init(
            canonical: "TextView",
            iosRoles: ["StaticText"],
            androidClassMatchers: [
                "android.widget.TextView",
                "androidx.appcompat.widget.AppCompatTextView",
                "com.google.android.material.textview.MaterialTextView",
            ]
        ),
        .init(
            canonical: "Switch",
            iosRoles: ["Switch"],
            androidClassMatchers: [
                "android.widget.Switch",
                "androidx.appcompat.widget.SwitchCompat",
                "com.google.android.material.switchmaterial.SwitchMaterial",
            ]
        ),
        .init(
            canonical: "Checkbox",
            iosRoles: ["CheckBox"],
            androidClassMatchers: [
                "android.widget.CheckBox",
                "androidx.appcompat.widget.AppCompatCheckBox",
                "com.google.android.material.checkbox.MaterialCheckBox",
            ]
        ),
        .init(
            canonical: "Image",
            iosRoles: ["Image"],
            androidClassMatchers: [
                "android.widget.ImageView",
                "androidx.appcompat.widget.AppCompatImageView",
            ]
        ),
        .init(
            canonical: "Link",
            iosRoles: ["Link"],
            androidClassMatchers: []
        ),
        .init(
            canonical: "NavigationBar",
            iosRoles: ["NavigationBar"],
            androidClassMatchers: [
                "androidx.appcompat.widget.Toolbar",
                "com.google.android.material.appbar.MaterialToolbar",
                "android.widget.Toolbar",
            ]
        ),
        .init(
            canonical: "Cell",
            iosRoles: ["Cell"],
            androidClassMatchers: [
                "androidx.recyclerview.widget.RecyclerView$ViewHolder",
            ]
        ),
        .init(
            canonical: "ScrollView",
            iosRoles: ["ScrollView"],
            androidClassMatchers: [
                "android.widget.ScrollView",
                "androidx.core.widget.NestedScrollView",
                "android.widget.HorizontalScrollView",
            ]
        ),
        .init(
            canonical: "List",
            iosRoles: ["Table", "CollectionView"],
            androidClassMatchers: [
                "androidx.recyclerview.widget.RecyclerView",
                "android.widget.ListView",
                "android.widget.GridView",
            ]
        ),
        .init(
            canonical: "Slider",
            iosRoles: ["Slider"],
            androidClassMatchers: [
                "android.widget.SeekBar",
                "com.google.android.material.slider.Slider",
            ]
        ),
        .init(
            canonical: "ProgressBar",
            iosRoles: ["ProgressIndicator", "ActivityIndicator"],
            androidClassMatchers: [
                "android.widget.ProgressBar",
            ]
        ),
    ]

    public static let canonicalNames: Set<String> = Set(mappings.map(\.canonical))

    /// Case-sensitive exact match on canonical names.
    public static func mapping(for canonical: String) -> ElementTypeMapping? {
        mappings.first { $0.canonical == canonical }
    }

    /// Match an Android `className` (full FQCN) against the vocabulary.
    /// Returns the canonical name of the first matching entry, or nil
    /// when no entry matches.
    ///
    /// Exact match only. Every matcher in the vocabulary is a fully-
    /// qualified Android framework / AndroidX / Material class
    /// owned by a specific package; a className living under a
    /// different package that merely *ends* with the same leaf
    /// segments (e.g. `com.evil.android.widget.Button`) is a
    /// distinct class and must not borrow the framework's
    /// classification. Custom subclasses fall through to the
    /// `shortClass` leaf-name fallback in `AndroidClassifier.role`,
    /// which is the same fate they would have had under any
    /// suffix-tolerant matcher — well-behaved Android apps override
    /// `View.getAccessibilityClassName()` to report the framework
    /// class for accessibility, so the exact-match path captures the
    /// real-world common case.
    public static func canonicalForAndroidClass(_ className: String) -> String? {
        for entry in mappings {
            if entry.androidClassMatchers.contains(className) {
                return entry.canonical
            }
        }
        return nil
    }
}