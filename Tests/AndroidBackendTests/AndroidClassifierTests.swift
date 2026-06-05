// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend
import SimUseCore

final class AndroidClassifierTests: XCTestCase {

    private func node(
        className: String,
        text: String = "",
        contentDescription: String = "",
        hintText: String? = nil,
        enabled: Bool = true,
        selected: Bool = false,
        checkable: Bool = false,
        checked: Bool = false,
        focused: Bool = false,
        password: Bool = false,
        bounds: ElementNode.Rect = .init(left: 0, top: 0, right: 100, bottom: 50)
    ) -> ElementNode {
        ElementNode(
            resourceId: "",
            package: "test",
            className: className,
            text: text,
            contentDescription: contentDescription,
            hintText: hintText,
            boundsInScreen: bounds,
            focused: focused,
            enabled: enabled,
            checkable: checkable,
            checked: checked,
            selected: selected,
            password: password
        )
    }

    // MARK: - role

    func testRoleResolvesCanonicalFromVocabulary() {
        XCTAssertEqual(AndroidClassifier.role(for: node(className: "android.widget.Button")), "Button")
        XCTAssertEqual(AndroidClassifier.role(for: node(className: "android.widget.EditText")), "TextField")
        XCTAssertEqual(AndroidClassifier.role(for: node(className: "androidx.recyclerview.widget.RecyclerView")), "List")
    }

    func testRoleFallsBackToShortClassName() {
        XCTAssertEqual(AndroidClassifier.role(for: node(className: "com.acme.app.CustomThing")), "CustomThing")
    }

    func testRoleFallsBackToElementWhenClassNameEmpty() {
        XCTAssertEqual(AndroidClassifier.role(for: node(className: "")), "Element")
    }

    // MARK: - declared regions

    func testToolbarBecomesNavBarWithLabel() {
        let n = node(className: "androidx.appcompat.widget.Toolbar", text: "Chats", contentDescription: "Chats")
        XCTAssertEqual(AndroidClassifier.declaredRegion(for: n)?.kind, "NavBar")
        XCTAssertEqual(AndroidClassifier.declaredRegion(for: n)?.label, "Chats")
    }

    func testToolbarStillBecomesNavBarWithoutLabel() {
        // NavBar/TabBar/AppBar — region carries even when label is empty
        // (they're structural and almost always region-worthy).
        let n = node(className: "androidx.appcompat.widget.Toolbar")
        XCTAssertEqual(AndroidClassifier.declaredRegion(for: n)?.kind, "NavBar")
    }

    func testBottomNavigationViewBecomesTabBar() {
        let n = node(className: "com.google.android.material.bottomnavigation.BottomNavigationView")
        XCTAssertEqual(AndroidClassifier.declaredRegion(for: n)?.kind, "TabBar")
    }

    func testScrollViewWithoutLabelDoesNotPromote() {
        // Generic ScrollView with no label is just a container; don't
        // pollute the outline with `[Scroll]` headers.
        let n = node(className: "android.widget.ScrollView")
        XCTAssertNil(AndroidClassifier.declaredRegion(for: n))
    }

    func testScrollViewWithLabelPromotesToScroll() {
        let n = node(className: "android.widget.ScrollView", contentDescription: "Main scroller")
        XCTAssertEqual(AndroidClassifier.declaredRegion(for: n)?.kind, "Scroll")
        XCTAssertEqual(AndroidClassifier.declaredRegion(for: n)?.label, "Main scroller")
    }

    func testNonContainerClassDoesNotPromote() {
        let n = node(className: "android.widget.Button", text: "Click")
        XCTAssertNil(AndroidClassifier.declaredRegion(for: n))
    }

    // MARK: - state tags

    func testDisabledTag() {
        let tags = AndroidClassifier.stateTags(role: "Button", node: node(className: "android.widget.Button", enabled: false), label: "X")
        XCTAssertTrue(tags.contains("disabled"))
    }

    func testSelectedTagFromSelectedFlag() {
        let tags = AndroidClassifier.stateTags(role: "Button", node: node(className: "android.widget.Button", selected: true), label: "X")
        XCTAssertTrue(tags.contains("selected"))
        XCTAssertFalse(tags.contains("checked"))
    }

    func testCheckedFlagOnSwitchSurfacesAsSelected() {
        let tags = AndroidClassifier.stateTags(role: "Switch", node: node(className: "android.widget.Switch", checkable: true, checked: true), label: "X")
        XCTAssertTrue(tags.contains("selected"))
        XCTAssertFalse(tags.contains("checked"))
        XCTAssertFalse(tags.contains("unchecked"))
    }

    func testCheckedOnNonSelectableShowsChecked() {
        // For a non-selectable role (e.g. plain View), `checked` shows
        // as its own tag, not "selected".
        let tags = AndroidClassifier.stateTags(role: "View", node: node(className: "android.view.View", checked: true), label: "X")
        XCTAssertTrue(tags.contains("checked"))
        XCTAssertFalse(tags.contains("selected"))
    }

    /// Compose's `Modifier.toggleable` produces a bare `android.view.View`
    /// node with `checkable=true` — no `Switch`/`Checkbox` class to key
    /// off. The classifier promotes it to the synthesized `Toggle`
    /// role so the binary semantic is visible in the outline. The state
    /// flows through `selectableRoles`: `checked=true` ➜ `selected`.
    func testCheckableBareViewBecomesToggleRole() {
        let on = node(className: "android.view.View", checkable: true, checked: true)
        XCTAssertEqual(AndroidClassifier.role(for: on), "Toggle")
        let onTags = AndroidClassifier.stateTags(role: "Toggle", node: on, label: "")
        XCTAssertTrue(onTags.contains("selected"))
        XCTAssertFalse(onTags.contains("unchecked"))
    }

    /// The OFF state for binary toggle widgets is explicit: without
    /// `unchecked`, an unchecked Compose toggle row would carry no
    /// state tag and look indistinguishable from a plain drill-down
    /// row. Switch / Checkbox / Toggle all share this contract.
    func testUncheckedTagOnOffToggle() {
        let off = node(className: "android.view.View", checkable: true, checked: false)
        let role = AndroidClassifier.role(for: off)
        XCTAssertEqual(role, "Toggle")
        let tags = AndroidClassifier.stateTags(role: role, node: off, label: "")
        XCTAssertTrue(tags.contains("unchecked"), "OFF toggle must surface `unchecked`; got tags=\(tags)")
        XCTAssertFalse(tags.contains("selected"))
        XCTAssertFalse(tags.contains("checked"))
    }

    /// Non-checkable bare View stays a plain View — no spurious
    /// Toggle promotion just because a ViewGroup happens to have no
    /// canonical class.
    func testNonCheckableViewStaysView() {
        XCTAssertEqual(
            AndroidClassifier.role(for: node(className: "android.view.View", checkable: false)),
            "View"
        )
    }

    func testFocusedAndPassword() {
        let tags = AndroidClassifier.stateTags(role: "TextField", node: node(className: "android.widget.EditText", focused: true, password: true), label: "")
        XCTAssertTrue(tags.contains("focused"))
        XCTAssertTrue(tags.contains("password"))
    }

    func testValueTagOnTextField() {
        let n = node(className: "android.widget.EditText", text: "hello@example.com")
        let tags = AndroidClassifier.stateTags(role: "TextField", node: n, label: "Email")
        XCTAssertTrue(tags.contains(where: { $0.starts(with: "value=") }))
    }

    func testValueTagTruncatesLongText() {
        let long = String(repeating: "x", count: 500)
        let n = node(className: "android.widget.EditText", text: long)
        let tags = AndroidClassifier.stateTags(role: "TextField", node: n, label: "")
        let valueTag = tags.first(where: { $0.starts(with: "value=") }) ?? ""
        XCTAssertTrue(valueTag.contains("…"))
        XCTAssertLessThan(valueTag.count, 40)
    }

    func testValueTagAbsentForNonValueRole() {
        let n = node(className: "android.widget.Button", text: "Click")
        let tags = AndroidClassifier.stateTags(role: "Button", node: n, label: "")
        XCTAssertFalse(tags.contains(where: { $0.starts(with: "value=") }))
    }

    /// Some Android Switch implementations expose distinct ON/OFF text
    /// (vendor-skinned settings, custom `Switch` subclasses that set
    /// `textOn`/`textOff`). When that text differs from the row label
    /// it carries useful semantic information beyond the binary
    /// `selected`/`unchecked` tags — surface it as `value="…"` so the
    /// outline matches iOS, which already emits a value tag for Switch
    /// (see `OutlineFormatter.valueBearingTypes`).
    func testValueTagOnSwitchWhenTextDistinct() {
        let n = node(
            className: "android.widget.Switch",
            text: "ON",
            contentDescription: "Bluetooth"
        )
        let tags = AndroidClassifier.stateTags(role: "Switch", node: n, label: "Bluetooth")
        XCTAssertTrue(
            tags.contains(where: { $0.starts(with: "value=") }),
            "Switch with distinct ON text should surface as `value=\"...\"`; got tags=\(tags)"
        )
    }

    /// Reverse parity case: a Switch whose `text` matches its label
    /// (the common case — most Switches have no separate textOn) keeps
    /// the existing behaviour. `effectiveValue` drops the duplicate, so
    /// no `value=` tag should appear and we don't double-print the
    /// label.
    func testValueTagAbsentOnSwitchWhenTextEqualsLabel() {
        let n = node(
            className: "android.widget.Switch",
            text: "Bluetooth",
            contentDescription: "Bluetooth"
        )
        let tags = AndroidClassifier.stateTags(role: "Switch", node: n, label: "Bluetooth")
        XCTAssertFalse(
            tags.contains(where: { $0.starts(with: "value=") }),
            "Switch where text==label should not emit a value tag; got tags=\(tags)"
        )
    }

    // MARK: - effective value

    func testEffectiveValueNilWhenTextEqualsLabel() {
        let n = node(className: "android.widget.EditText", text: "X")
        XCTAssertNil(AndroidClassifier.effectiveValue(node: n, label: "X"))
    }

    func testEffectiveValueNilWhenTextIsHint() {
        let n = node(className: "android.widget.EditText", text: "Phone", hintText: "Phone")
        XCTAssertNil(AndroidClassifier.effectiveValue(node: n, label: "X"))
    }

    func testEffectiveValueReturnsTextWhenDistinct() {
        let n = node(className: "android.widget.EditText", text: "real input")
        XCTAssertEqual(AndroidClassifier.effectiveValue(node: n, label: "Email"), "real input")
    }
}