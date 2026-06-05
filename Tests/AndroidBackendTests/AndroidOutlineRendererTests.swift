// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend
import SimUseCore

final class AndroidOutlineRendererTests: XCTestCase {

    /// Builds a minimal LINE-like a11y tree:
    ///   root window
    ///     ├── Toolbar "Chats"
    ///     │     └── TextView "Friends"
    ///     ├── RecyclerView
    ///     │     ├── Cell "Alice"
    ///     │     └── Cell "Bob"
    ///     └── BottomNavigationView
    ///           ├── Button "Home" (selected)
    ///           └── Button "Chats"
    private func makeFixture() -> ElementNode {
        let toolbar = ElementNode(
            resourceId: "com.example.app:id/main_toolbar",
            package: "com.example.app",
            className: "androidx.appcompat.widget.Toolbar",
            text: "Chats",
            contentDescription: "Chats",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 168),
            children: [
                ElementNode(
                    resourceId: "com.example.app:id/title",
                    package: "com.example.app",
                    className: "android.widget.TextView",
                    text: "Friends",
                    contentDescription: "",
                    boundsInScreen: .init(left: 40, top: 40, right: 500, bottom: 120)
                )
            ]
        )
        let cellAlice = ElementNode(
            resourceId: "com.example.app:id/chatroom_cell",
            package: "com.example.app",
            className: "android.widget.FrameLayout",
            text: "",
            contentDescription: "Alice",
            boundsInScreen: .init(left: 0, top: 200, right: 1080, bottom: 400),
            clickable: true
        )
        let cellBob = ElementNode(
            resourceId: "com.example.app:id/chatroom_cell",
            package: "com.example.app",
            className: "android.widget.FrameLayout",
            text: "",
            contentDescription: "Bob",
            boundsInScreen: .init(left: 0, top: 400, right: 1080, bottom: 600),
            clickable: true
        )
        let recycler = ElementNode(
            resourceId: "com.example.app:id/chat_list",
            package: "com.example.app",
            className: "androidx.recyclerview.widget.RecyclerView",
            text: "",
            contentDescription: "",
            boundsInScreen: .init(left: 0, top: 200, right: 1080, bottom: 1700),
            scrollable: true,
            children: [cellAlice, cellBob]
        )
        let bnbHome = ElementNode(
            resourceId: "com.example.app:id/home_tab",
            uniqueId: "home_tab",
            package: "com.example.app",
            className: "androidx.appcompat.widget.AppCompatButton",
            text: "Home",
            contentDescription: "Home",
            boundsInScreen: .init(left: 0, top: 1800, right: 540, bottom: 1920),
            clickable: true,
            selected: true
        )
        let bnbChats = ElementNode(
            resourceId: "com.example.app:id/chats_tab",
            uniqueId: "chats_tab",
            package: "com.example.app",
            className: "androidx.appcompat.widget.AppCompatButton",
            text: "Chats",
            contentDescription: "Chats",
            boundsInScreen: .init(left: 540, top: 1800, right: 1080, bottom: 1920),
            clickable: true,
            selected: false
        )
        let bnb = ElementNode(
            resourceId: "com.example.app:id/bottom_nav",
            package: "com.example.app",
            className: "com.google.android.material.bottomnavigation.BottomNavigationView",
            text: "",
            contentDescription: "Bottom navigation",
            boundsInScreen: .init(left: 0, top: 1800, right: 1080, bottom: 1920),
            children: [bnbHome, bnbChats]
        )
        return ElementNode(
            resourceId: "",
            package: "com.example.app",
            className: "android.widget.FrameLayout",
            text: "",
            contentDescription: "LINE",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [toolbar, recycler, bnb]
        )
    }

    func testRendersHeaderAndScreenBounds() {
        let outline = AndroidOutlineRenderer.render(root: makeFixture())
        XCTAssertEqual(outline.screen.width, 1080)
        XCTAssertEqual(outline.screen.height, 1920)
        XCTAssertEqual(outline.appLabel, "LINE")
        XCTAssertTrue(outline.text.contains("App: LINE  1080x1920"))
    }

    func testEntriesHaveAliasesAndUniqueIds() {
        let outline = AndroidOutlineRenderer.render(root: makeFixture())
        XCTAssertFalse(outline.entries.isEmpty)
        let aliases = outline.entries.map { $0.aliases.at }
        XCTAssertEqual(aliases, Array(1...outline.entries.count))

        let homeEntry = outline.entries.first { $0.uniqueId == "home_tab" }
        XCTAssertNotNil(homeEntry)
        XCTAssertEqual(homeEntry?.label, "Home")
        XCTAssertTrue(homeEntry?.states.contains("selected") ?? false)

        let chatsEntry = outline.entries.first { $0.uniqueId == "chats_tab" }
        XCTAssertEqual(chatsEntry?.resourceId, "chats_tab")
    }

    func testListDetectorAssignsListAliases() {
        let outline = AndroidOutlineRenderer.render(root: makeFixture())
        // RecyclerView with 2 cells → one Tier-1 list, both cells get aliases.
        let cellAliases = outline.entries.compactMap { $0.aliases.list }
        XCTAssertGreaterThanOrEqual(cellAliases.count, 2)
        XCTAssertEqual(cellAliases.first?.scope, 1)
        XCTAssertEqual(outline.lists.count, 1)
        XCTAssertEqual(outline.lists[0].cellCount, 2)
        XCTAssertEqual(outline.lists[0].score, 1.0)
    }

    func testFiltersOffscreenByDefault() {
        let offscreenChild = ElementNode(
            resourceId: "",
            package: "test",
            className: "android.widget.TextView",
            text: "Off",
            contentDescription: "",
            boundsInScreen: .init(left: 2000, top: 500, right: 2200, bottom: 600)
        )
        let onscreenChild = ElementNode(
            resourceId: "",
            package: "test",
            className: "android.widget.TextView",
            text: "On",
            contentDescription: "",
            boundsInScreen: .init(left: 0, top: 500, right: 200, bottom: 600)
        )
        let root = ElementNode(
            resourceId: "",
            package: "test",
            className: "android.widget.FrameLayout",
            text: "",
            contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [offscreenChild, onscreenChild]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let labels = outline.entries.map(\.label)
        XCTAssertTrue(labels.contains("On"))
        XCTAssertFalse(labels.contains("Off"))

        let withOffscreen = AndroidOutlineRenderer.render(
            root: root,
            options: AndroidOutlineRenderer.RendererOptions(filterOffscreen: false)
        )
        XCTAssertTrue(withOffscreen.entries.map(\.label).contains("Off"))
    }

    /// Regression: popups / dialogs whose root window is offset from
    /// (0,0) and smaller than the device used to silently drop every
    /// node beyond `screen.width` / `screen.height`, because the
    /// offscreen filter compared absolute frame coords against the
    /// window's *size* instead of its absolute edges. Six items in a
    /// menu collapsed to three. Now, with the bridge-supplied
    /// `display` metrics the renderer correctly uses device bounds.
    func testPopupOffsetDoesNotDropNodesBeyondWindowSize() {
        // Synthesize the LINE long-tap menu that surfaced this bug:
        // root window at (372, 274, 708×883) — but items sit at
        // x>=826 ("Add friends") and y>=908 ("Edit chats" /
        // "Mark all as read") which are >= window size yet well
        // within the 1080×2400 device.
        func wrapper(label: String, frame: ElementNode.Rect) -> ElementNode {
            ElementNode(
                resourceId: "",
                package: "com.example.app",
                className: "android.view.View",
                text: "",
                contentDescription: "",
                boundsInScreen: frame,
                clickable: true,
                focusable: true,
                children: [
                    ElementNode(
                        resourceId: "",
                        package: "com.example.app",
                        className: "android.widget.TextView",
                        text: label,
                        contentDescription: "",
                        boundsInScreen: frame
                    )
                ]
            )
        }
        let root = ElementNode(
            resourceId: "android:id/content",
            package: "com.example.app",
            className: "android.view.ViewGroup",
            text: "",
            contentDescription: "",
            boundsInScreen: .init(left: 372, top: 274, right: 1080, bottom: 1157),
            children: [
                wrapper(label: "Create a chat",    frame: .init(left: 398, top: 274,  right: 626,  bottom: 532)),
                wrapper(label: "Create group",     frame: .init(left: 626, top: 274,  right: 826,  bottom: 532)),
                wrapper(label: "Add friends",      frame: .init(left: 826, top: 274,  right: 1054, bottom: 532)),
                wrapper(label: "Edit chats",       frame: .init(left: 398, top: 908,  right: 1054, bottom: 1018)),
                wrapper(label: "Mark all as read", frame: .init(left: 398, top: 1018, right: 1054, bottom: 1144)),
            ]
        )
        let outline = AndroidOutlineRenderer.render(
            root: root,
            display: DisplayMetrics(width: 1080, height: 2400)
        )
        let labels = outline.entries.map(\.label)
        XCTAssertTrue(labels.contains("Add friends"),      "x=826 fell beyond window.width=708 and was dropped")
        XCTAssertTrue(labels.contains("Edit chats"),       "y=908 fell beyond window.height=883 and was dropped")
        XCTAssertTrue(labels.contains("Mark all as read"), "y=1018 fell beyond window.height=883 and was dropped")
        XCTAssertTrue(outline.text.contains("1080x2400"), "header should report device bounds, not window bounds")
        // All items are well within the device's Content band
        // (280..2120 on a 2400-tall screen); none should be tagged
        // Bottom just because they sit in the lower half of the
        // popup window.
        let regions = Set(outline.entries.map(\.region.kind))
        XCTAssertEqual(regions, ["Content"], "popup items mis-zoned by window-relative yBand")
    }

    /// PopupWindow-style overlays (LINE chat menu, Spinner dropdowns,
    /// PopupMenu) render in a separate accessibility window that
    /// `service.rootInActiveWindow` cannot reach. The bridge wraps the
    /// active root + each secondary-window root under a synthetic node
    /// stamped with the `__simuse:multi_window__` marker.
    ///
    /// When the wrapper has 2+ children, the renderer **drops the
    /// active root** and emits only secondary-window contents. This
    /// matches iOS `UIContextMenu` behavior (the framework marks the
    /// surrounding UI as non-accessible while a context menu is up)
    /// and is the right surface for agents: any tap that lands on
    /// active-window items during a modal popup dismisses the popup
    /// rather than firing the row, so listing those items would
    /// invite misuse. The active root still drives the `App: <name>`
    /// header so context isn't lost.
    func testMultiWindowMarkerDropsActiveAndRendersOnlySecondaryWindowItems() {
        // Active window: a chat row that should NOT appear once a
        // popup is up — tapping it would dismiss the popup, not
        // re-trigger the row.
        let activeRoot = ElementNode(
            resourceId: "android:id/content",
            package: "com.example.app",
            className: "android.widget.FrameLayout",
            text: "",
            contentDescription: "Hello World",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [
                ElementNode(
                    resourceId: "com.example.app:id/chat_ui_row_text_message",
                    package: "com.example.app",
                    className: "android.widget.LinearLayout",
                    text: "メキシコ代表",
                    contentDescription: "メキシコ代表",
                    boundsInScreen: .init(left: 336, top: 389, right: 1059, bottom: 594),
                    clickable: true
                )
            ]
        )
        // Secondary window: the long-press action menu (PopupWindow).
        // Bounds intentionally sit in the upper-middle of the device,
        // overlapping the active window — that's the LINE case.
        let popupRoot = ElementNode(
            resourceId: "",
            package: "com.example.app",
            className: "android.view.ViewGroup",
            text: "",
            contentDescription: "Showing context menu",
            boundsInScreen: .init(left: 331, top: 594, right: 1064, bottom: 1107),
            children: [
                ElementNode(
                    resourceId: "com.example.app:id/chat_ui_message_context_content_layout",
                    package: "com.example.app",
                    className: "android.widget.Button",
                    text: "Copy",
                    contentDescription: "Copy",
                    boundsInScreen: .init(left: 331, top: 612, right: 512, bottom: 775),
                    clickable: true
                ),
                ElementNode(
                    resourceId: "com.example.app:id/chat_ui_message_context_content_layout",
                    package: "com.example.app",
                    className: "android.widget.Button",
                    text: "Delete",
                    contentDescription: "Delete",
                    boundsInScreen: .init(left: 880, top: 612, right: 1064, bottom: 775),
                    clickable: true
                ),
            ]
        )
        // Synthetic wrapper — matches what the bridge emits when
        // `collectSecondaryAppWindowTrees` returns a non-empty list.
        let multiRoot = ElementNode(
            resourceId: "__simuse:multi_window__",
            package: "com.example.app",
            className: "__simuse:multi_window__",
            text: "",
            contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [activeRoot, popupRoot]
        )

        let outline = AndroidOutlineRenderer.render(
            root: multiRoot,
            display: DisplayMetrics(width: 1080, height: 2400)
        )
        let labels = outline.entries.map(\.label)
        // Active-window content must be suppressed — the modal popup
        // makes it un-tappable for the duration of the menu.
        XCTAssertFalse(labels.contains("メキシコ代表"),
                       "active-window chat row leaked into outline despite popup being modal")
        // Popup contents must be present.
        XCTAssertTrue(labels.contains("Copy"),   "popup item 'Copy' missing")
        XCTAssertTrue(labels.contains("Delete"), "popup item 'Delete' missing")
        // Aliases run continuously over the surviving (popup-only)
        // entries — no holes from suppressed active entries.
        XCTAssertEqual(outline.entries.map(\.aliases.at), Array(1...outline.entries.count))
        // The synthetic wrapper itself never renders as an entry.
        XCTAssertFalse(labels.contains("__simuse:multi_window__"))
        // Screen / app label come from the device dimensions and the
        // active window's package — so the header still reads
        // "App: <foreground app>" even though active items are gone.
        XCTAssertEqual(outline.screen.width, 1080)
        XCTAssertEqual(outline.screen.height, 2400)
    }

    /// Regression: `clickable` wrapper Views with a single labeled
    /// TextView child used to render as two separate rows (the
    /// wrapper via `clickable`, the child via label) — doubling
    /// outline noise. Now they fold into one `Button` row using
    /// the wrapper's frame.
    func testClickableWrapperFoldsWithSingleTextChild() {
        let child = ElementNode(
            resourceId: "",
            package: "test",
            className: "android.widget.TextView",
            text: "Submit",
            contentDescription: "",
            boundsInScreen: .init(left: 20, top: 20, right: 100, bottom: 60)
        )
        let wrapper = ElementNode(
            resourceId: "",
            package: "test",
            className: "android.view.View",
            text: "",
            contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 200, bottom: 100),
            clickable: true,
            focusable: true,
            children: [child]
        )
        let root = ElementNode(
            resourceId: "",
            package: "test",
            className: "android.widget.FrameLayout",
            text: "",
            contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [wrapper]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let submitEntries = outline.entries.filter { $0.label == "Submit" }
        XCTAssertEqual(submitEntries.count, 1, "wrapper + child collapsed to one row")
        XCTAssertEqual(submitEntries.first?.role, "Button")
        XCTAssertEqual(submitEntries.first?.frame.width, 200, "fold keeps wrapper's larger tap zone")
    }

    /// Fold MUST eat a non-interactable labeled child even when the
    /// child has a resource_id. A child that isn't clickable /
    /// long-clickable / checkable can't be addressed as a tap target
    /// on its own — its id is decorative. The wrapper is the real
    /// tap target, so the wrapper's frame + id is what callers want.
    /// Fold rolls a wrapper-with-no-uniqueId over a child that DOES
    /// carry one. The resulting outline entry must keep the child's
    /// `uniqueId` so a downstream `tap --id <inner-uniqueId>` (the
    /// stability handle that survives label changes) still lands on
    /// the wrapper's hit zone. Before the fix the wrapper's empty
    /// `uniqueId` overwrote the child's and `--id` returned
    /// `.noMatch`.
    func testFoldPropagatesInnerUniqueId() {
        let child = ElementNode(
            resourceId: "",
            uniqueId: "settings_row_label",
            package: "test",
            className: "android.widget.TextView",
            text: "Settings",
            contentDescription: "",
            boundsInScreen: .init(left: 20, top: 20, right: 200, bottom: 80)
        )
        // Wrapper carries no uniqueId — only the inner label has one.
        let wrapper = ElementNode(
            resourceId: "",
            uniqueId: nil,
            package: "test",
            className: "android.view.View",
            text: "",
            contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 300, bottom: 100),
            clickable: true,
            children: [child]
        )
        let root = ElementNode(
            resourceId: "",
            package: "test",
            className: "android.widget.FrameLayout",
            text: "",
            contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [wrapper]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let settingsEntries = outline.entries.filter { $0.label == "Settings" }
        XCTAssertEqual(settingsEntries.count, 1, "wrapper + non-interactable child fold into one row")
        XCTAssertEqual(
            settingsEntries.first?.uniqueId,
            "settings_row_label",
            "child's uniqueId must propagate onto the folded entry — without it `tap --id settings_row_label` no longer finds the row even though the inner element still exists in the live AX tree"
        )
        XCTAssertEqual(settingsEntries.first?.frame.width, 300,
                       "wrapper's hit zone (the actual tap target) is preserved")
    }

    /// Regression guard for the inverse: when the wrapper carries a
    /// uniqueId and the inner child doesn't, the wrapper's id must
    /// stay on the folded entry. The fix prefers the inner id only
    /// when one exists.
    func testFoldKeepsWrapperUniqueIdWhenChildHasNone() {
        let child = ElementNode(
            resourceId: "",
            uniqueId: nil,
            package: "test",
            className: "android.widget.TextView",
            text: "Submit",
            contentDescription: "",
            boundsInScreen: .init(left: 20, top: 20, right: 100, bottom: 60)
        )
        let wrapper = ElementNode(
            resourceId: "",
            uniqueId: "submit_button_wrapper",
            package: "test",
            className: "android.view.View",
            text: "",
            contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 200, bottom: 100),
            clickable: true,
            children: [child]
        )
        let root = ElementNode(
            resourceId: "",
            package: "test",
            className: "android.widget.FrameLayout",
            text: "",
            contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [wrapper]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let entries = outline.entries.filter { $0.label == "Submit" }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.uniqueId, "submit_button_wrapper")
    }

    func testFoldEatsNonInteractableChildEvenWithResourceId() {
        let child = ElementNode(
            resourceId: "com.example.app:id/submit_label",
            package: "test",
            className: "android.widget.TextView",
            text: "Submit",
            contentDescription: "",
            boundsInScreen: .init(left: 20, top: 20, right: 100, bottom: 60)
        )
        let wrapper = ElementNode(
            resourceId: "com.example.app:id/submit_button",
            package: "test",
            className: "android.view.View",
            text: "",
            contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 200, bottom: 100),
            clickable: true,
            children: [child]
        )
        let root = ElementNode(
            resourceId: "",
            package: "test",
            className: "android.widget.FrameLayout",
            text: "",
            contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [wrapper]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let submitEntries = outline.entries.filter { $0.label == "Submit" }
        XCTAssertEqual(submitEntries.count, 1, "wrapper + non-interactable child fold into one row")
        XCTAssertEqual(submitEntries.first?.resourceId, "submit_button",
                       "wrapper's id (the tap target) wins")
        XCTAssertEqual(submitEntries.first?.frame.width, 200, "wrapper's hit zone preserved")
    }

    /// An interactable inner button must survive separately — it's a
    /// real sub-button (think: a delete-X icon inside a chat row).
    func testFoldSkippedWhenInnerChildIsInteractable() {
        let innerButton = ElementNode(
            resourceId: "com.example.app:id/inner_btn",
            package: "test",
            className: "android.widget.ImageButton",
            text: "",
            contentDescription: "Delete",
            boundsInScreen: .init(left: 150, top: 30, right: 190, bottom: 70),
            clickable: true
        )
        let label = ElementNode(
            resourceId: "",
            package: "test",
            className: "android.widget.TextView",
            text: "Item",
            contentDescription: "",
            boundsInScreen: .init(left: 20, top: 30, right: 120, bottom: 70)
        )
        let wrapper = ElementNode(
            resourceId: "",
            package: "test",
            className: "android.view.View",
            text: "",
            contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 200, bottom: 100),
            clickable: true,
            children: [label, innerButton]
        )
        let root = ElementNode(
            resourceId: "",
            package: "test",
            className: "android.widget.FrameLayout",
            text: "",
            contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [wrapper]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        // Two labeled descendants at the same depth — fold is
        // ambiguous and skipped. Both rows survive.
        let labels = outline.entries.map(\.label)
        XCTAssertTrue(labels.contains("Item"))
        XCTAssertTrue(labels.contains("Delete"), "interactable inner button must remain addressable")
    }

    /// LINE's invitee picker shape: each row is a clickable ViewGroup
    /// containing a thumbnail Image, a TextView name, and a checkbox
    /// Image. The fold collapses the wrapper + name into a single
    /// `Button "<name>"` entry, but all Image children — thumbnail
    /// (the row's avatar) and checkbox (the row's selected state) —
    /// must stay addressable. Earlier revisions of the renderer ate
    /// both as "decoration"; the current policy is to keep Images
    /// visible across the fold pipeline.
    func testRowIconsAndCheckboxAllSurviveButtonFold() {
        let row = ElementNode(
            resourceId: "com.example.app:id/select_invitee_info_row_background",
            package: "test", className: "android.widget.LinearLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 1038, right: 1080, bottom: 1193),
            clickable: true,
            focusable: true,
            children: [
                // Thumbnail — the row's avatar. User-visible, must stay.
                ElementNode(
                    resourceId: "com.example.app:id/select_invitee_info_row_thumbnail",
                    package: "test", className: "android.widget.ImageView",
                    text: "", contentDescription: "",
                    boundsInScreen: .init(left: 42, top: 1062, right: 152, bottom: 1172)
                ),
                // Name — folds into the row, label "ccc".
                ElementNode(
                    resourceId: "com.example.app:id/select_invitee_info_row_name",
                    package: "test", className: "android.widget.TextView",
                    text: "ccc", contentDescription: "",
                    boundsInScreen: .init(left: 245, top: 1088, right: 926, bottom: 1144)
                ),
                // Checkbox — empty label, non-interactable, carries
                // the row's selection state via the drawable.
                ElementNode(
                    resourceId: "com.example.app:id/select_invitee_info_row_checkbox",
                    package: "test", className: "android.widget.ImageView",
                    text: "", contentDescription: "",
                    boundsInScreen: .init(left: 978, top: 1084, right: 1041, bottom: 1147)
                ),
            ]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [row]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let rowEntry = outline.entries.first { $0.resourceId == "select_invitee_info_row_background" }
        XCTAssertEqual(rowEntry?.role, "Button", "labelled-child fold still promotes the row to Button")
        XCTAssertEqual(rowEntry?.label, "ccc")
        XCTAssertTrue(
            outline.entries.contains { $0.resourceId == "select_invitee_info_row_thumbnail" },
            "thumbnail Image survives — it's part of what the user sees"
        )
        XCTAssertTrue(
            outline.entries.contains { $0.resourceId == "select_invitee_info_row_checkbox" },
            "checkbox Image survives — it carries the row's selection state"
        )
    }

    /// Header-button shape: clickable wrapper > labeled middle layer >
    /// inner Image with a generic content description.
    ///
    /// The fold rolls the wrapper + middle layer into one row with the
    /// middle layer's label adopted by the wrapper (so the Button uses
    /// the wrapper's larger hit-zone). The redundant middle FrameLayout
    /// itself is dropped (it's the chosen-for-fold target). The inner
    /// Image survives: even when its content description duplicates the
    /// row's role, an Image is part of what the user sees on screen and
    /// we no longer silently drop them.
    func testHeaderButtonShapeFoldsButKeepsInnerImage() {
        let inner = ElementNode(
            resourceId: "com.example.app:id/header_button_layout",
            package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "Settings button",
            boundsInScreen: .init(left: 956, top: 132, right: 1056, bottom: 274),
            children: [
                ElementNode(
                    resourceId: "com.example.app:id/header_button_img",
                    package: "test", className: "android.widget.ImageView",
                    text: "", contentDescription: "Close",
                    boundsInScreen: .init(left: 956, top: 153, right: 1056, bottom: 253)
                )
            ]
        )
        let wrapper = ElementNode(
            resourceId: "com.example.app:id/settings_header_button",
            package: "test", className: "android.widget.LinearLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 956, top: 132, right: 1056, bottom: 274),
            clickable: true,
            focusable: true,
            children: [inner]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [wrapper]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let settings = outline.entries.filter { $0.resourceId == "settings_header_button" }
        XCTAssertEqual(settings.count, 1)
        XCTAssertEqual(settings.first?.label, "Settings button")
        XCTAssertFalse(
            outline.entries.contains { $0.resourceId == "header_button_layout" },
            "redundant middle FrameLayout is swept (its label was adopted by the wrapper)"
        )
        XCTAssertTrue(
            outline.entries.contains { $0.resourceId == "header_button_img" },
            "inner Image survives the fold — Images are user-visible content, not decoration to drop"
        )
    }

    /// Class-name substring matches must not trip the
    /// SlidingPaneLayout drop. A third-party class whose name
    /// happens to contain `SlidingPaneLayout` (vendor wrapper,
    /// custom-fork class) previously silenced one of its child
    /// subtrees because the substring match was too greedy. Anchor
    /// to the suffix `.SlidingPaneLayout` so the drop only fires
    /// for the canonical class.
    func testSlidingPaneLayoutVariantClassDoesNotTriggerDrop() {
        let labelLeft = ElementNode(
            resourceId: "", package: "test", className: "android.widget.TextView",
            text: "Left pane", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 540, bottom: 100)
        )
        let labelRight = ElementNode(
            resourceId: "", package: "test", className: "android.widget.TextView",
            text: "Right pane", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 540, bottom: 100)
        )
        let pane0 = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 540, bottom: 100),
            children: [labelLeft]
        )
        let pane1 = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 540, bottom: 100),
            children: [labelRight]
        )
        // Class name contains "SlidingPaneLayout" but is NOT the
        // canonical androidx class. Previously triggered the drop
        // via substring match; should now be left alone.
        let fakeSliding = ElementNode(
            resourceId: "", package: "test",
            className: "com.acme.fancy.MySlidingPaneLayoutWrapper",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 540, bottom: 100),
            children: [pane0, pane1]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [fakeSliding]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let labels = outline.entries.map(\.label)
        XCTAssertTrue(
            labels.contains("Left pane"),
            "Non-canonical SlidingPaneLayout-named class must not drop its first child subtree; got entries: \(labels)"
        )
        XCTAssertTrue(labels.contains("Right pane"))
    }

    /// `longClickable` wrappers are still buttons from a user-tap
    /// perspective — they're the standard shape for the iOS-style
    /// "context menu" trigger (`onLongPress`). When the fold rule
    /// collapses such a wrapper onto its inner label, the resulting
    /// entry should carry role `Button` so `--element-type Button`
    /// resolves it. Previously only `clickable` triggered the
    /// promotion; long-press-only wrappers kept the inner child's
    /// role (often `View`) and silently fell off `Button`
    /// selectors.
    func testLongClickableWrapperFoldsAsButton() {
        let label = ElementNode(
            resourceId: "", package: "test", className: "android.widget.TextView",
            text: "Chat", contentDescription: "",
            boundsInScreen: .init(left: 20, top: 20, right: 200, bottom: 80)
        )
        let wrapper = ElementNode(
            resourceId: "", package: "test", className: "android.view.View",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 300, bottom: 100),
            clickable: false,
            longClickable: true,
            children: [label]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [wrapper]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let entries = outline.entries.filter { $0.label == "Chat" }
        XCTAssertEqual(entries.count, 1, "wrapper + child fold")
        XCTAssertEqual(
            entries.first?.role,
            "Button",
            "longClickable wrappers should fold-promote to Button so `--element-type Button` reaches them."
        )
    }

    /// Regression: `SlidingPaneLayout` (the androidx Material
    /// list-detail container used by LINE's
    /// `LineUserSettingsTwoPaneFragmentActivity`) keeps BOTH the
    /// master pane and the detail pane attached with identical
    /// full-screen bounds in narrow-screen single-pane mode. Only
    /// the open pane is drawn but a11y reports both subtrees —
    /// every Settings → Account / Privacy / etc. outline used to
    /// ghost the master pane's rows under the detail's. Drop the
    /// master subtree when both panes overlap and both are
    /// populated.
    func testSlidingPaneLayoutSinglePaneDropsMasterGhosts() {
        // Master pane (Settings root) — would surface "Profile" and
        // "Account" as ghost rows.
        let masterContent = ElementNode(
            resourceId: "test:id/settings_root", package: "test",
            className: "android.widget.LinearLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [
                ElementNode(resourceId: "", package: "test",
                            className: "android.widget.TextView",
                            text: "Profile", contentDescription: "",
                            boundsInScreen: .init(left: 42, top: 400, right: 400, bottom: 460)),
                ElementNode(resourceId: "", package: "test",
                            className: "android.widget.TextView",
                            text: "Account", contentDescription: "",
                            boundsInScreen: .init(left: 42, top: 600, right: 400, bottom: 660)),
            ]
        )
        let masterPane = ElementNode(
            resourceId: "test:id/navigation_pane", package: "test",
            className: "android.widget.FrameLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [masterContent]
        )
        // Detail pane (Account screen) — should be the only one
        // surfaced.
        let detailContent = ElementNode(
            resourceId: "test:id/account_root", package: "test",
            className: "android.widget.LinearLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [
                ElementNode(resourceId: "", package: "test",
                            className: "android.widget.TextView",
                            text: "Phone number", contentDescription: "",
                            boundsInScreen: .init(left: 42, top: 400, right: 400, bottom: 460)),
                ElementNode(resourceId: "", package: "test",
                            className: "android.widget.TextView",
                            text: "Email address", contentDescription: "",
                            boundsInScreen: .init(left: 42, top: 600, right: 400, bottom: 660)),
            ]
        )
        let detailPane = ElementNode(
            resourceId: "", package: "test",
            className: "android.widget.FrameLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [detailContent]
        )
        let slidingPane = ElementNode(
            resourceId: "", package: "test",
            className: "androidx.slidingpanelayout.widget.SlidingPaneLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [masterPane, detailPane]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [slidingPane]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let labels = outline.entries.map(\.label)
        XCTAssertTrue(labels.contains("Phone number"))
        XCTAssertTrue(labels.contains("Email address"))
        XCTAssertFalse(labels.contains("Profile"), "master pane Profile row leaked through")
        XCTAssertFalse(labels.contains("Account"), "master pane Account row leaked through")
    }

    /// Counter-case: when only the master pane has content (user is
    /// on Settings root, no detail loaded yet), the drop rule must
    /// NOT fire — otherwise the user-visible content would vanish.
    func testSlidingPaneLayoutKeepsMasterWhenDetailEmpty() {
        let masterContent = ElementNode(
            resourceId: "", package: "test", className: "android.widget.TextView",
            text: "Settings list item", contentDescription: "",
            boundsInScreen: .init(left: 42, top: 400, right: 400, bottom: 460)
        )
        let masterPane = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [masterContent]
        )
        let emptyDetailPane = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: []
        )
        let slidingPane = ElementNode(
            resourceId: "", package: "test",
            className: "androidx.slidingpanelayout.widget.SlidingPaneLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [masterPane, emptyDetailPane]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [slidingPane]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        XCTAssertTrue(outline.entries.contains { $0.label == "Settings list item" },
                      "master content must survive when detail is empty")
    }

    /// Counter-case: tablet two-pane mode lays the panes side-by-side
    /// with different x bounds. The rule must NOT fire there —
    /// both panes are genuinely visible.
    func testSlidingPaneLayoutKeepsBothPanesInTabletSideBySide() {
        let masterContent = ElementNode(
            resourceId: "", package: "test", className: "android.widget.TextView",
            text: "Master item", contentDescription: "",
            boundsInScreen: .init(left: 42, top: 400, right: 400, bottom: 460)
        )
        let masterPane = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 540, bottom: 2400),
            children: [masterContent]
        )
        let detailContent = ElementNode(
            resourceId: "", package: "test", className: "android.widget.TextView",
            text: "Detail item", contentDescription: "",
            boundsInScreen: .init(left: 580, top: 400, right: 900, bottom: 460)
        )
        let detailPane = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 540, top: 0, right: 1080, bottom: 2400),
            children: [detailContent]
        )
        let slidingPane = ElementNode(
            resourceId: "", package: "test",
            className: "androidx.slidingpanelayout.widget.SlidingPaneLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [masterPane, detailPane]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [slidingPane]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let labels = outline.entries.map(\.label)
        XCTAssertTrue(labels.contains("Master item"))
        XCTAssertTrue(labels.contains("Detail item"))
    }

    /// Regression: `visibleToUser=false` nodes from the bridge
    /// (`AccessibilityNodeInfo.isVisibleToUser()` == false) must not
    /// surface as outline rows. Older bridges that omit the field
    /// default to `true` via `decodeIfPresent`, so behaviour is
    /// unchanged when the field is absent.
    func testVisibleToUserFalseDropsNode() {
        let hidden = ElementNode(
            resourceId: "test:id/hidden", package: "test",
            className: "android.widget.TextView",
            text: "Hidden text", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 100, right: 200, bottom: 160),
            visibleToUser: false
        )
        let visible = ElementNode(
            resourceId: "test:id/visible", package: "test",
            className: "android.widget.TextView",
            text: "Visible text", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 200, right: 200, bottom: 260),
            visibleToUser: true
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [hidden, visible]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let labels = outline.entries.map(\.label)
        XCTAssertFalse(labels.contains("Hidden text"))
        XCTAssertTrue(labels.contains("Visible text"))
    }

    /// Older bridges that don't emit `visibleToUser` must keep working
    /// — `decodeIfPresent` defaults the field to `true`, preserving
    /// pre-bump behaviour.
    func testLegacyBridgePayloadWithoutVisibleToUserDecodes() throws {
        let legacy = #"""
        {
          "resourceId": "test:id/x",
          "uniqueId": null,
          "package": "test",
          "className": "android.widget.TextView",
          "text": "Legacy",
          "contentDescription": "",
          "hintText": null,
          "stateDescription": null,
          "boundsInScreen": { "left": 0, "top": 0, "right": 100, "bottom": 50 },
          "clickable": false,
          "longClickable": false,
          "scrollable": false,
          "focusable": false,
          "focused": false,
          "enabled": true,
          "checkable": false,
          "checked": false,
          "selected": false,
          "password": false,
          "collectionInfo": null,
          "collectionItemInfo": null,
          "children": []
        }
        """#
        let node = try JSONDecoder().decode(ElementNode.self, from: Data(legacy.utf8))
        XCTAssertEqual(node.text, "Legacy")
        XCTAssertTrue(node.visibleToUser, "legacy payloads (no field) default to true")
    }

    /// Regression: literal `"null"` strings in contentDescription or
    /// text used to surface as `Image "null"` rows — Java toString of
    /// a null reference / placeholder constants that escaped. Treat
    /// the literal 4-char `"null"` as empty.
    func testLiteralNullContentDescriptionTreatedAsEmpty() {
        let badImage = ElementNode(
            resourceId: "test:id/ai_icon", package: "test",
            className: "android.widget.ImageView",
            text: "", contentDescription: "null",
            boundsInScreen: .init(left: 0, top: 100, right: 80, bottom: 180)
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [badImage]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let entry = outline.entries.first { $0.resourceId == "ai_icon" }
        XCTAssertNotNil(entry, "icon should still survive via resource_id")
        XCTAssertEqual(entry?.label, "", "literal \"null\" string must not become a label")
    }

    /// Regression: full-screen layout primitives like
    /// `:action_bar_root:` / `:content:` / `:app_main_root:` /
    /// `:viewpager:` used to surface as outline rows just because
    /// they expose a resource_id. They're not addressable for the
    /// agent and the full-screen frame is never a useful tap target.
    func testFullScreenPureContainerDropped() {
        let actionBarRoot = ElementNode(
            resourceId: "android:id/action_bar_root",
            package: "test", className: "android.widget.LinearLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400)
        )
        let content = ElementNode(
            resourceId: "android:id/content",
            package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400)
        )
        let pager = ElementNode(
            resourceId: "com.example.app:id/viewpager",
            package: "test", className: "androidx.viewpager.widget.ViewPager",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2271),
            scrollable: true
        )
        let realButton = ElementNode(
            resourceId: "test:id/ok", package: "test",
            className: "android.widget.Button",
            text: "OK", contentDescription: "",
            boundsInScreen: .init(left: 100, top: 200, right: 300, bottom: 280),
            clickable: true
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [actionBarRoot, content, pager, realButton]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let resourceIds = outline.entries.compactMap(\.resourceId)
        XCTAssertFalse(resourceIds.contains("action_bar_root"))
        XCTAssertFalse(resourceIds.contains("content"))
        XCTAssertFalse(resourceIds.contains("viewpager"))
        XCTAssertTrue(resourceIds.contains("ok"), "addressable button must survive")
    }

    /// Regression: cell children sorted by center-y used to interleave
    /// with their cell container — a chat row at (y=273, h=179,
    /// center=362) sorted *after* its TextView children at
    /// (y=317, h=34..47, center=338..340). Sorting by top edge keeps
    /// each cell row immediately before its own children.
    func testListCellPrecedesItsChildrenInOutlineOrder() {
        // Mirror the LINE chat row shape: container at y=273, h=179
        // with avatar / name / timestamp / preview children inside.
        let avatar = ElementNode(
            resourceId: "", package: "test", className: "android.view.View",
            text: "", contentDescription: "Avatar",
            boundsInScreen: .init(left: 42, top: 300, right: 205, bottom: 426)
        )
        let name = ElementNode(
            resourceId: "", package: "test", className: "android.widget.TextView",
            text: "Alice", contentDescription: "",
            boundsInScreen: .init(left: 205, top: 317, right: 346, bottom: 364)
        )
        let timestamp = ElementNode(
            resourceId: "", package: "test", className: "android.widget.TextView",
            text: "9:24 AM", contentDescription: "",
            boundsInScreen: .init(left: 934, top: 321, right: 1038, bottom: 355)
        )
        let preview = ElementNode(
            resourceId: "", package: "test", className: "android.widget.TextView",
            text: "Hello", contentDescription: "",
            boundsInScreen: .init(left: 205, top: 369, right: 428, bottom: 409)
        )
        let row = ElementNode(
            resourceId: "", package: "test", className: "android.view.View",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 273, right: 1080, bottom: 452),
            clickable: true,
            children: [avatar, name, timestamp, preview]
        )
        let list = ElementNode(
            resourceId: "chat_list", package: "test",
            className: "androidx.recyclerview.widget.RecyclerView",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 273, right: 1080, bottom: 800),
            children: [
                row,
                ElementNode(
                    resourceId: "", package: "test", className: "android.view.View",
                    text: "", contentDescription: "",
                    boundsInScreen: .init(left: 0, top: 453, right: 1080, bottom: 631),
                    clickable: true
                ),
            ]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [list]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        // Find the row entry (frame y=273, h=179) and the name entry
        // (label="Alice"). The row must appear first.
        guard let rowIdx = outline.entries.firstIndex(where: { $0.frame.y == 273 && $0.frame.height == 179 }),
              let nameIdx = outline.entries.firstIndex(where: { $0.label == "Alice" }) else {
            XCTFail("expected row + name entries"); return
        }
        XCTAssertLessThan(rowIdx, nameIdx, "list cell must precede its children in outline order")
    }

    /// Toggle rows (synthesized role for Compose `Modifier.toggleable`
    /// shape) and full-width Settings rows should anchor their child
    /// TextViews even though they carry no `#N` list alias. Without
    /// this, a Settings screen — where every row is unique and the
    /// list detector picks up nothing — renders entirely flat,
    /// defeating the indent feature for the most common screen
    /// pattern the agent sees.
    /// `aliases.at` (the `@N` reader sees in the outline and what
    /// Viewer / selectors index by) must match the DFS-preorder
    /// print position, not the underlying y-sort dedupe position.
    /// Without renumbering, `@1, @2, @3, …` would skip around when a
    /// parent's child gets pushed below a later sibling by y-sort.
    func testAtAliasesMatchCanonicalPrintOrder() {
        // Two header buttons whose icons live at y=153 — y-sort
        // creates entries in the order [btn0, btn1, icon0, icon1],
        // but DFS preorder prints [btn0, icon0, btn1, icon1]. The
        // `at` values on the rendered entries must match the printed
        // sequence.
        func btn(_ tag: String, x: Int) -> ElementNode {
            ElementNode(
                resourceId: "btn_\(tag)", package: "test",
                className: "android.widget.LinearLayout",
                text: "", contentDescription: "Button \(tag)",
                boundsInScreen: .init(left: x, top: 132, right: x + 100, bottom: 274),
                clickable: true,
                children: [
                    ElementNode(
                        resourceId: "icon_\(tag)", package: "test",
                        className: "android.widget.ImageView",
                        text: "", contentDescription: "icon",
                        boundsInScreen: .init(left: x, top: 153, right: x + 100, bottom: 253)
                    )
                ]
            )
        }
        let header = ElementNode(
            resourceId: "header", package: "test", className: "android.view.ViewGroup",
            text: "", contentDescription: "Header",
            boundsInScreen: .init(left: 0, top: 132, right: 1080, bottom: 274),
            children: [btn("a", x: 656), btn("b", x: 756)]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [header]
        )
        let outline = AndroidOutlineRenderer.render(root: root)

        // Entries array order matches print order — assert by
        // walking the array and checking `at == idx + 1`.
        for (idx, entry) in outline.entries.enumerated() {
            XCTAssertEqual(entry.aliases.at, idx + 1,
                "entry at position \(idx) must carry aliases.at=\(idx+1), got \(entry.aliases.at)")
        }

        // The first 5 entries in print order should be header, btn_a,
        // icon_a, btn_b, icon_b — `@1..@5` in that exact sequence.
        let expectedOrder = [
            ("header",  "@1"),
            ("btn_a",   "@2"),
            ("icon_a",  "@3"),
            ("btn_b",   "@4"),
            ("icon_b",  "@5"),
        ]
        for (i, (resource, expectedAt)) in expectedOrder.enumerated() {
            XCTAssertEqual(outline.entries[i].resourceId, resource,
                           "entry \(i): expected resource '\(resource)', got '\(outline.entries[i].resourceId ?? "nil")'")
            XCTAssertEqual("@\(outline.entries[i].aliases.at)", expectedAt,
                           "entry \(i): expected \(expectedAt), got @\(outline.entries[i].aliases.at)")
        }

        // Spot-check the rendered text: lines should show `@1..@5`
        // in the same sequence as their `at` values, no gaps.
        let entryLines = outline.text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("@") }
        for (i, line) in entryLines.prefix(5).enumerated() {
            XCTAssertTrue(line.contains("@\(i + 1) "), "expected `@\(i+1) ` in line: \(line)")
        }
    }

    /// LINE's home-tab header is a flat ViewGroup containing 4
    /// `HeaderButton` LinearLayouts (each wrapping a FrameLayout
    /// labelled by `setButtonContentDescription` and an inner
    /// `header_button_img` ImageView). After fold each header button
    /// surfaces as a `Button "..."` entry at y=132, and the inner
    /// images all appear at y=153 — y-sorted, they'd cluster after
    /// the buttons with no visual link to which Button they belong
    /// to. With 2-level indent + DFS preorder rearrange, each Image
    /// must appear *immediately* after its containing Button, two
    /// levels deep.
    func testTwoLevelIndentReordersByContainment() {
        // Outer header ViewGroup (full-width row, ~6% screen height).
        let headerChildren: [ElementNode] = (0..<3).map { i in
            // 3 buttons side-by-side at y=132, each 100×142.
            let x = 656 + i * 100
            return ElementNode(
                resourceId: "btn_\(i)", package: "test",
                className: "android.widget.LinearLayout",
                text: "", contentDescription: "Button \(i)",
                boundsInScreen: .init(left: x, top: 132, right: x + 100, bottom: 274),
                clickable: true,
                children: [
                    // Inner image — same x range, y=153, 100×100.
                    ElementNode(
                        resourceId: "icon_\(i)", package: "test",
                        className: "android.widget.ImageView",
                        text: "", contentDescription: "icon",
                        boundsInScreen: .init(left: x, top: 153, right: x + 100, bottom: 253)
                    )
                ]
            )
        }
        let header = ElementNode(
            resourceId: "header", package: "test", className: "android.view.ViewGroup",
            text: "", contentDescription: "Header",
            boundsInScreen: .init(left: 0, top: 132, right: 1080, bottom: 274),
            children: headerChildren
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [header]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let lines = outline.text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("@") }    // Just the entry lines.

        // Each Button must be immediately followed by ITS image (DFS
        // preorder), not all buttons first and all images later.
        for i in 0..<3 {
            guard let btnIdx = lines.firstIndex(where: { $0.contains("\"Button \(i)\"") }) else {
                XCTFail("missing button \(i) in:\n\(outline.text)"); return
            }
            // Image must appear right after its button.
            XCTAssertLessThan(btnIdx + 1, lines.count, "no entry after button \(i)")
            let imgIdx = btnIdx + 1
            XCTAssertTrue(
                lines[imgIdx].contains(":icon_\(i):"),
                "icon \(i) should immediately follow Button \(i); got\n  btn line: \(lines[btnIdx])\n  next:    \(lines[imgIdx])"
            )

            // Image is indented 2 deeper than its button.
            let btnPad = lines[btnIdx].prefix { $0 == " " }.count
            let imgPad = lines[imgIdx].prefix { $0 == " " }.count
            XCTAssertEqual(imgPad - btnPad, 2,
                           "icon_\(i) should be one level deeper than its parent Button (got btnPad=\(btnPad), imgPad=\(imgPad))")
        }

        // Header ViewGroup is two levels above each Image — verify
        // explicitly that the max indent caps at 4 spaces beyond the
        // base lead-in.
        guard let headerIdx = lines.firstIndex(where: { $0.contains(":header:") }),
              let firstIconIdx = lines.firstIndex(where: { $0.contains(":icon_0:") }) else {
            XCTFail("expected header + icon_0 in:\n\(outline.text)"); return
        }
        let headerPad = lines[headerIdx].prefix { $0 == " " }.count
        let iconPad = lines[firstIconIdx].prefix { $0 == " " }.count
        XCTAssertEqual(iconPad - headerPad, 4,
                       "icon should be 2 levels deeper than its grandparent header")
    }

    func testToggleRowAndWideRowAnchorTheirChildren() {
        // Wide non-toggle row: width = full screen, contains both a
        // label TextView and a description TextView. Two labelled
        // descendants keep `foldContainerText` from collapsing the
        // wrapper into a Button (which would lose the anchor shape),
        // matching the Settings-row pattern observed on LINE. All
        // y coordinates sit in the Content y-band (>= 280) so the
        // row and its children share the same outline bucket.
        let drillRow = ElementNode(
            resourceId: "", package: "test", className: "android.view.View",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 700, right: 1080, bottom: 960),
            clickable: true,
            children: [
                ElementNode(
                    resourceId: "", package: "test", className: "android.widget.TextView",
                    text: "Group name", contentDescription: "",
                    boundsInScreen: .init(left: 42, top: 730, right: 400, bottom: 790)
                ),
                ElementNode(
                    resourceId: "", package: "test", className: "android.widget.TextView",
                    text: "one dog, Wang Wei", contentDescription: "",
                    boundsInScreen: .init(left: 42, top: 800, right: 1000, bottom: 860)
                )
            ]
        )
        // Toggle row: checkable=true on bare View, label + description.
        let toggleRow = ElementNode(
            resourceId: "", package: "test", className: "android.view.View",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 1000, right: 1080, bottom: 1260),
            clickable: true,
            checkable: true,
            checked: true,
            children: [
                ElementNode(
                    resourceId: "", package: "test", className: "android.widget.TextView",
                    text: "Note notifications", contentDescription: "",
                    boundsInScreen: .init(left: 42, top: 1030, right: 800, bottom: 1090)
                ),
                ElementNode(
                    resourceId: "", package: "test", className: "android.widget.TextView",
                    text: "Get notified when someone leaves a comment", contentDescription: "",
                    boundsInScreen: .init(left: 42, top: 1100, right: 1000, bottom: 1180)
                )
            ]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [drillRow, toggleRow]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let lines = outline.text.split(separator: "\n", omittingEmptySubsequences: false)

        // Drill row's label is indented relative to the row entry.
        guard let drillRowIdx = lines.firstIndex(where: { line in
                  line.contains(" View ") && !line.contains("\"Group name\"")
                  && line.contains("(0,700")
              }),
              let drillLabelIdx = lines.firstIndex(where: { $0.contains("\"Group name\"") }) else {
            XCTFail("expected drill-row + label in:\n\(outline.text)"); return
        }
        let drillRowPad = lines[drillRowIdx].prefix { $0 == " " }.count
        let drillLabelPad = lines[drillLabelIdx].prefix { $0 == " " }.count
        XCTAssertEqual(drillLabelPad - drillRowPad, 2,
                       "Settings drill-row should anchor its label child for indent")

        // Toggle row is classified as Toggle and anchors its label.
        guard let toggleRowIdx = lines.firstIndex(where: { $0.contains(" Toggle ") }),
              let toggleLabelIdx = lines.firstIndex(where: { $0.contains("\"Note notifications\"") }) else {
            XCTFail("expected toggle-row + label in:\n\(outline.text)"); return
        }
        let toggleRowPad = lines[toggleRowIdx].prefix { $0 == " " }.count
        let toggleLabelPad = lines[toggleLabelIdx].prefix { $0 == " " }.count
        XCTAssertEqual(toggleLabelPad - toggleRowPad, 2,
                       "Toggle row should anchor its label child for indent")
        XCTAssertTrue(lines[toggleRowIdx].contains("selected"),
                      "Toggle row with checked=true should carry `selected` state tag")
    }

    /// LINE's invitee picker emits per-row containers
    /// `:select_invitee_info_row_background:` that are `clickable=true`
    /// for selectable rows and `clickable=false` for already-selected
    /// ones (the "Recent chats" row, the same contact mirrored back
    /// into Friends below). The non-clickable variant tripped
    /// `includeNode`'s pure-container drop and got removed,
    /// orphaning its thumbnail / name children at the outline's top
    /// level.
    ///
    /// Fix: when a node's `resourceIdShortName` repeats among its
    /// siblings (≥ 2 occurrences under the same parent), it's part of
    /// a list-cell pattern and survives the structural-wrapper drop
    /// even with empty label + non-interactable. A genuinely
    /// structural wrapper (`:action_bar_root:`, unique under its
    /// parent) still gets dropped.
    func testNonClickableRowContainerSurvivesWhenIdRepeatsAmongSiblings() {
        // Three siblings, all sharing :row_bg:, all NOT clickable.
        // Each owns a labelled TextView child so we can assert the
        // children land under their container (and not orphaned).
        func row(top: Int, name: String) -> ElementNode {
            ElementNode(
                resourceId: "row_bg", package: "test", className: "android.view.ViewGroup",
                text: "", contentDescription: "",
                boundsInScreen: .init(left: 0, top: top, right: 1080, bottom: top + 155),
                children: [
                    ElementNode(
                        resourceId: "name", package: "test", className: "android.widget.TextView",
                        text: name, contentDescription: "",
                        boundsInScreen: .init(left: 100, top: top + 50, right: 800, bottom: top + 100)
                    )
                ]
            )
        }
        // Control: a single pure-container wrapper at the bottom with
        // a UNIQUE resource id. This one should still get dropped.
        let unique = ElementNode(
            resourceId: "skeleton_wrapper", package: "test", className: "android.view.ViewGroup",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 800, right: 1080, bottom: 900),
            children: [
                ElementNode(
                    resourceId: "skel_text", package: "test", className: "android.widget.TextView",
                    text: "Header", contentDescription: "",
                    boundsInScreen: .init(left: 100, top: 820, right: 800, bottom: 870)
                )
            ]
        )
        let list = ElementNode(
            resourceId: "", package: "test",
            className: "androidx.recyclerview.widget.RecyclerView",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 300, right: 1080, bottom: 900),
            children: [
                row(top: 300, name: "Alice"),
                row(top: 455, name: "Bob"),
                row(top: 610, name: "Carol"),
                unique,
            ]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [list]
        )
        let outline = AndroidOutlineRenderer.render(root: root)

        // All three repeating-id row containers survive.
        let rowEntries = outline.entries.filter { $0.resourceId == "row_bg" }
        XCTAssertEqual(rowEntries.count, 3,
                       "all three :row_bg: containers should survive — they form a repeating list-cell pattern")

        // The unique-id skeleton wrapper still gets dropped (control).
        XCTAssertFalse(
            outline.entries.contains { $0.resourceId == "skeleton_wrapper" },
            "unique-id pure-container skeleton wrapper should still be dropped"
        )
        // But its TextView child survives (the wrapper-drop doesn't
        // cascade into the subtree).
        XCTAssertTrue(
            outline.entries.contains { $0.label == "Header" },
            "TextView inside the dropped skeleton still surfaces"
        )

        // Each row's name child stays addressable by its row's frame.
        for name in ["Alice", "Bob", "Carol"] {
            XCTAssertTrue(
                outline.entries.contains { $0.label == name },
                "TextView '\(name)' must survive under its container"
            )
        }
    }

    /// List-cell children get +2 spaces of indent in the rendered
    /// outline so the agent can read "what's inside this row" at a
    /// glance. The anchor is narrow on purpose: only entries that
    /// already carry a `#N` list alias indent their contained
    /// descendants, so a top-level navbar or a non-list clickable
    /// wrapper doesn't drag the rest of the screen rightward.
    ///
    /// Shape mirrors LINE's invitee picker row: clickable ViewGroup
    /// with the row label + thumbnail Image + checkbox Image + an
    /// extra labelled icon ("Official account"). All four leaves must
    /// land under their cell.
    func testListCellChildrenAreIndentedInRenderedText() {
        // First cell — the "anchor" we expect to indent under.
        let cell1 = ElementNode(
            resourceId: "row_bg", package: "test", className: "android.view.ViewGroup",
            text: "", contentDescription: "Alice",
            boundsInScreen: .init(left: 0, top: 1038, right: 1080, bottom: 1193),
            clickable: true,
            children: [
                ElementNode(resourceId: "thumb", package: "test",
                            className: "android.widget.ImageView",
                            text: "", contentDescription: "",
                            boundsInScreen: .init(left: 42, top: 1062, right: 152, bottom: 1172)),
                ElementNode(resourceId: "check", package: "test",
                            className: "android.widget.ImageView",
                            text: "", contentDescription: "",
                            boundsInScreen: .init(left: 978, top: 1084, right: 1041, bottom: 1147)),
            ]
        )
        // Second cell to anchor the test's "indent resets between
        // cells" expectation.
        let cell2 = ElementNode(
            resourceId: "row_bg", package: "test", className: "android.view.ViewGroup",
            text: "", contentDescription: "Bob",
            boundsInScreen: .init(left: 0, top: 1193, right: 1080, bottom: 1348),
            clickable: true,
            children: [
                ElementNode(resourceId: "thumb", package: "test",
                            className: "android.widget.ImageView",
                            text: "", contentDescription: "",
                            boundsInScreen: .init(left: 42, top: 1217, right: 152, bottom: 1327)),
            ]
        )
        let list = ElementNode(
            resourceId: "members", package: "test",
            className: "androidx.recyclerview.widget.RecyclerView",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 1038, right: 1080, bottom: 1348),
            children: [cell1, cell2]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [list]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        let lines = outline.text.split(separator: "\n", omittingEmptySubsequences: false)

        // Locate the lines that mention Alice's row and one of its
        // children — assert the child is indented an extra two spaces
        // beyond the cell row.
        guard let cellIdx = lines.firstIndex(where: { $0.contains("\"Alice\"") }),
              let childIdx = lines.firstIndex(where: { $0.contains(":check:") }) else {
            XCTFail("expected cell + checkbox lines in:\n\(outline.text)"); return
        }
        XCTAssertGreaterThan(childIdx, cellIdx, "child line must come after its cell line")
        let cellPad = lines[cellIdx].prefix { $0 == " " }.count
        let childPad = lines[childIdx].prefix { $0 == " " }.count
        XCTAssertEqual(childPad - cellPad, 2,
                       "list-cell children should indent +2 vs the cell row; got cellPad=\(cellPad) childPad=\(childPad)")

        // Bob's row should be back at the cell-row indent — the anchor
        // resets across cells, it doesn't stack.
        guard let cell2Idx = lines.firstIndex(where: { $0.contains("\"Bob\"") }) else {
            XCTFail("expected Bob row"); return
        }
        let cell2Pad = lines[cell2Idx].prefix { $0 == " " }.count
        XCTAssertEqual(cell2Pad, cellPad, "second cell should sit at the same indent as the first, not nested")
    }

    /// Real-world shape from LINE's News tab: a ListView whose direct
    /// children are labelless "padding" wrappers that just add a few
    /// pixels of vertical whitespace around an inner labelled View. The
    /// wrappers themselves get filtered out by `includeNode` (empty
    /// label + non-interactable + pure-container class), so the
    /// outline only ever sees the inner Views. But the list detector
    /// still reports the wrappers' frames as the cluster's cell frames,
    /// because that's what the ListView directly contains.
    ///
    /// Without the containment fallback in alias attribution the inner
    /// rows fail their `aliasByFrame` lookup and the outline ends up
    /// showing only `#1` and `#last` — middle rows lose the `#N`
    /// alias entirely (the symptom that prompted this fix).
    func testListAliasAttributedThroughSingleChildPaddingWrapper() {
        // Three padding wrappers, each containing one labelled inner.
        // Outer frame is 16px taller (top -8, bottom +8) than the inner
        // — matches the LINE news-card shape (outer 1000×226, inner
        // 1000×194).
        func paddedRow(top: Int, label: String) -> ElementNode {
            let inner = ElementNode(
                resourceId: "", package: "test", className: "android.view.View",
                text: "", contentDescription: label,
                boundsInScreen: .init(left: 42, top: top + 8, right: 1042, bottom: top + 8 + 194)
            )
            return ElementNode(
                // Pure-container wrapper: empty label, non-interactable,
                // android.view.View — exactly what `includeNode` drops.
                resourceId: "", package: "test", className: "android.view.View",
                text: "", contentDescription: "",
                boundsInScreen: .init(left: 42, top: top, right: 1042, bottom: top + 226),
                children: [inner]
            )
        }
        let list = ElementNode(
            resourceId: "", package: "test",
            className: "androidx.recyclerview.widget.RecyclerView",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 500, right: 1080, bottom: 2200),
            children: [
                paddedRow(top: 500, label: "News 1"),
                paddedRow(top: 730, label: "News 2"),
                paddedRow(top: 960, label: "News 3"),
            ]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "App",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [list]
        )
        let outline = AndroidOutlineRenderer.render(root: root)

        // All three padding wrappers should be filtered out (no outer
        // 1000×226 entries surface in the outline).
        XCTAssertFalse(
            outline.entries.contains { $0.frame.height == 226 },
            "padding wrappers should be filtered by includeNode"
        )

        // Each inner row gets its expected #N alias at scope=1.
        for (i, label) in ["News 1", "News 2", "News 3"].enumerated() {
            guard let entry = outline.entries.first(where: { $0.label == label }) else {
                XCTFail("missing entry for \(label)"); continue
            }
            XCTAssertNotNil(entry.aliases.list, "\(label) lost its list alias")
            XCTAssertEqual(entry.aliases.list?.scope, 1, "\(label) wrong scope")
            XCTAssertEqual(entry.aliases.list?.index, i + 1, "\(label) wrong index")
        }
    }

    func testEditTextValueAndHintRoundtrip() {
        let editText = ElementNode(
            resourceId: "com.example.app:id/phone_input",
            package: "com.example.app",
            className: "android.widget.EditText",
            text: "Phone number",
            contentDescription: "",
            hintText: "Phone number",
            boundsInScreen: .init(left: 0, top: 400, right: 1080, bottom: 500),
            focusable: true
        )
        let root = ElementNode(
            resourceId: "",
            package: "com.example.app",
            className: "android.widget.FrameLayout",
            text: "",
            contentDescription: "Login",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 1920),
            children: [editText]
        )
        let outline = AndroidOutlineRenderer.render(root: root)
        // hint == text means the user hasn't typed anything; label
        // should be empty (so we don't pretend the hint is the label),
        // but `hint` field should still surface for callers.
        let entry = outline.entries.first { $0.resourceId == "phone_input" }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.label, "")
        XCTAssertEqual(entry?.hint, "Phone number")
        XCTAssertNil(entry?.value)
    }
}