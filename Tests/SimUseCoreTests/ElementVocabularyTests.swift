// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import SimUseCore

final class ElementVocabularyTests: XCTestCase {

    func testButtonMatchesAndroidWidget() {
        XCTAssertEqual(ElementVocabulary.canonicalForAndroidClass("android.widget.Button"), "Button")
        XCTAssertEqual(ElementVocabulary.canonicalForAndroidClass("com.google.android.material.button.MaterialButton"), "Button")
    }

    func testTextFieldMatchesEditText() {
        XCTAssertEqual(ElementVocabulary.canonicalForAndroidClass("android.widget.EditText"), "TextField")
    }

    func testNonMatchingClassReturnsNil() {
        XCTAssertNil(ElementVocabulary.canonicalForAndroidClass("com.example.CustomWidget"))
    }

    func testMappingForCanonical() {
        let button = ElementVocabulary.mapping(for: "Button")
        XCTAssertNotNil(button)
        XCTAssertTrue(button!.iosRoles.contains("Button"))
        XCTAssertTrue(button!.androidClassMatchers.contains("android.widget.Button"))
    }

    func testCanonicalNamesIncludesAllExpected() {
        let expected: Set<String> = [
            "Button", "TextField", "TextView", "Switch", "Checkbox", "Image",
            "Link", "NavigationBar", "Cell", "ScrollView", "List", "Slider", "ProgressBar",
        ]
        XCTAssertTrue(expected.isSubset(of: ElementVocabulary.canonicalNames))
    }
}