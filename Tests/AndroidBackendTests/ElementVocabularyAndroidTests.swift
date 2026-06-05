// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend
import SimUseCore

/// Cross-target coverage: vocabulary is exposed through SimUseCore but
/// must remain stable for AndroidBackend selectors. These tests check
/// the bindings AndroidBackend depends on.
final class ElementVocabularyAndroidTests: XCTestCase {

    func testAllAndroidMatchersAreFullyQualified() {
        for entry in ElementVocabulary.mappings {
            for matcher in entry.androidClassMatchers {
                XCTAssertTrue(matcher.contains("."),
                              "\(entry.canonical) → matcher \(matcher) must be a fully qualified class name")
            }
        }
    }

    func testCanonicalForClassDoesNotMatchPartialPrefix() {
        // Exact match only. Substring / prefix / suffix collisions must
        // not classify — every matcher in the vocabulary is a fully-
        // qualified Android framework / AndroidX / Material class
        // owned by a specific package, so a className that just
        // happens to end with the matcher (under a different package)
        // is a different class.
        XCTAssertNil(ElementVocabulary.canonicalForAndroidClass("Buttons"))
        XCTAssertNil(ElementVocabulary.canonicalForAndroidClass("notMyButton.android.widget.Button.fake"))
        // Namespace-attack guard: a custom class living at
        // `com.evil.android.widget.Button` is a distinct class from
        // the framework's `android.widget.Button`. Suffix matching
        // would silently classify it as a Button; exact match
        // refuses.
        XCTAssertNil(ElementVocabulary.canonicalForAndroidClass("com.evil.android.widget.Button"))
        XCTAssertNil(ElementVocabulary.canonicalForAndroidClass("com.spoof.androidx.recyclerview.widget.RecyclerView"))
    }

    func testRoleAndCanonicalAgreeOnBuiltinClasses() {
        let cases: [(String, String)] = [
            ("android.widget.Button", "Button"),
            ("android.widget.EditText", "TextField"),
            ("android.widget.TextView", "TextView"),
            ("android.widget.ImageView", "Image"),
            ("androidx.recyclerview.widget.RecyclerView", "List"),
        ]
        for (cls, expected) in cases {
            XCTAssertEqual(ElementVocabulary.canonicalForAndroidClass(cls), expected, "for class \(cls)")
        }
    }

    func testUnknownClassReturnsNil() {
        XCTAssertNil(ElementVocabulary.canonicalForAndroidClass("com.unknown.widget.Whatever"))
    }
}