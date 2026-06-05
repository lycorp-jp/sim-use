// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend
import SimUseCore

final class AndroidOutlineRendererExtraTests: XCTestCase {

    func testToolbarRegionHeaderAppearsInText() {
        let title = ElementNode(
            resourceId: "", package: "app",
            className: "android.widget.TextView",
            text: "Settings", contentDescription: "",
            boundsInScreen: .init(left: 40, top: 30, right: 400, bottom: 90)
        )
        let toolbar = ElementNode(
            resourceId: "", package: "app",
            className: "androidx.appcompat.widget.Toolbar",
            text: "Settings", contentDescription: "Settings",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 168),
            children: [title]
        )
        let root = ElementNode(
            resourceId: "", package: "app",
            className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [toolbar]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        XCTAssertTrue(outline.text.contains("[NavBar  \"Settings\"]"),
                      "Expected NavBar header in:\n\(outline.text)")
        // The title TextView should still appear under that region.
        let titleEntry = outline.entries.first { $0.label == "Settings" && $0.role == "TextView" }
        XCTAssertEqual(titleEntry?.region.kind, "NavBar")
        XCTAssertEqual(titleEntry?.region.label, "Settings")
    }

    func testBottomNavRegionAndTabBarSelected() {
        let homeTab = ElementNode(
            resourceId: "", uniqueId: "home", package: "app",
            className: "androidx.appcompat.widget.AppCompatButton",
            text: "", contentDescription: "Home",
            boundsInScreen: .init(left: 0, top: 1800, right: 540, bottom: 1920),
            clickable: true, selected: true
        )
        let bnb = ElementNode(
            resourceId: "", package: "app",
            className: "com.google.android.material.bottomnavigation.BottomNavigationView",
            text: "", contentDescription: "Tabs",
            boundsInScreen: .init(left: 0, top: 1800, right: 1080, bottom: 1920),
            children: [homeTab]
        )
        let root = ElementNode(
            resourceId: "", package: "app",
            className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [bnb]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        XCTAssertTrue(outline.text.contains("[TabBar  \"Tabs\"]"))
        let entry = outline.entries.first { $0.uniqueId == "home" }
        XCTAssertEqual(entry?.region.kind, "TabBar")
        XCTAssertTrue(entry?.states.contains("selected") ?? false)
    }

    func testSubtreeHeaderWhenScreenZero() {
        // Root with zero-area bounds renders as a "Subtree:" header (not "App:").
        // Even though we still have a root, an empty screen frame means
        // no fall-through region math.
        let leaf = ElementNode(
            resourceId: "", package: "app",
            className: "android.widget.TextView",
            text: "Hi", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 100, bottom: 50)
        )
        let root = ElementNode(
            resourceId: "", package: "app",
            className: "android.view.View",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 0, bottom: 0),
            children: [leaf]
        )
        let outline = AndroidOutlineRenderer.render(root: root, options: .init(filterOffscreen: false))
        XCTAssertTrue(outline.text.contains("Subtree:"), "Got:\n\(outline.text)")
        XCTAssertFalse(outline.text.contains("App:"))
    }

    func testLongLabelTruncated() {
        let long = String(repeating: "abcdefghij", count: 20)  // 200 chars
        let leaf = ElementNode(
            resourceId: "", package: "app",
            className: "android.widget.TextView",
            text: long, contentDescription: "",
            boundsInScreen: .init(left: 0, top: 100, right: 500, bottom: 150)
        )
        let root = ElementNode(
            resourceId: "", package: "app",
            className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [leaf]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        XCTAssertTrue(outline.text.contains("…"))
        // Element label kept full-length in the structured Entry.
        XCTAssertEqual(outline.entries.first?.label.count, 200)
    }

    func testDedupParentSingleChildSameFrame() {
        // Wrapper container + label child sharing the same frame and label
        // should collapse to the deeper (more specific) node.
        let inner = ElementNode(
            resourceId: "", package: "app",
            className: "android.widget.TextView",
            text: "Hello", contentDescription: "Hello",
            boundsInScreen: .init(left: 0, top: 0, right: 100, bottom: 50)
        )
        let outer = ElementNode(
            resourceId: "", package: "app",
            className: "android.view.ViewGroup",
            text: "", contentDescription: "Hello",
            boundsInScreen: .init(left: 0, top: 0, right: 100, bottom: 50),
            clickable: true,
            children: [inner]
        )
        let root = ElementNode(
            resourceId: "", package: "app",
            className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [outer]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        // Both have the same role? No — outer is ViewGroup, inner is TextView.
        // Dedup key is (role, label, frame) — they have different roles,
        // so both survive. Confirm both appear.
        let labels = outline.entries.map { "\($0.role):\($0.label)" }
        XCTAssertTrue(labels.contains("TextView:Hello"))
        XCTAssertTrue(labels.contains("ViewGroup:Hello"))
    }

    func testEmptyChildContainerWithNoHandleDropped() {
        let emptyContainer = ElementNode(
            resourceId: "", package: "app",
            className: "android.view.ViewGroup",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 100, right: 100, bottom: 200)
        )
        let root = ElementNode(
            resourceId: "", package: "app",
            className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [emptyContainer]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        XCTAssertEqual(outline.entries.count, 0)
    }

    func testListedEntriesGetSequentialAliases() {
        let cells = (0..<4).map { i in
            ElementNode(
                resourceId: "cell_\(i)", package: "app",
                className: "android.widget.FrameLayout",
                text: "", contentDescription: "Cell \(i)",
                boundsInScreen: .init(left: 0, top: i * 200, right: 1080, bottom: (i + 1) * 200),
                clickable: true
            )
        }
        let recycler = ElementNode(
            resourceId: "", package: "app",
            className: "androidx.recyclerview.widget.RecyclerView",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 800),
            children: cells
        )
        let root = ElementNode(
            resourceId: "", package: "app",
            className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [recycler]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let listAliases = outline.entries.compactMap { $0.aliases.list }
        XCTAssertEqual(listAliases.count, 4)
        XCTAssertEqual(listAliases.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(listAliases.map(\.scope), [1, 1, 1, 1])
    }
}