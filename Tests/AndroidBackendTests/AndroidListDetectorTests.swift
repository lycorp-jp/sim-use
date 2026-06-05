// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend
import SimUseCore

final class AndroidListDetectorTests: XCTestCase {

    private func leaf(width: Int = 1080, height: Int = 200, top: Int = 0) -> ElementNode {
        ElementNode(
            resourceId: "",
            package: "test",
            className: "android.view.View",
            text: "",
            contentDescription: "",
            boundsInScreen: .init(left: 0, top: top, right: width, bottom: top + height)
        )
    }

    private func collection(
        className: String,
        cellTops: [Int],
        bounds: ElementNode.Rect = .init(left: 0, top: 0, right: 1080, bottom: 2400),
        contentDescription: String = "",
        collectionInfo: ElementNode.CollectionInfo? = nil
    ) -> ElementNode {
        let cells = cellTops.map { leaf(top: $0) }
        return ElementNode(
            resourceId: "",
            package: "test",
            className: className,
            text: "",
            contentDescription: contentDescription,
            boundsInScreen: bounds,
            collectionInfo: collectionInfo,
            children: cells
        )
    }

    func testEmptyTreeProducesNoClusters() {
        let empty = ElementNode(
            resourceId: "", package: "test", className: "android.view.View",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 100, bottom: 100)
        )
        XCTAssertEqual(AndroidListDetector.detect(root: empty).count, 0)
    }

    func testRecyclerViewDetected() {
        let root = collection(className: "androidx.recyclerview.widget.RecyclerView", cellTops: [0, 200, 400])
        let clusters = AndroidListDetector.detect(root: root)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].score, 1.0)
        XCTAssertEqual(clusters[0].cellFrames.count, 3)
        XCTAssertEqual(clusters[0].cellHeight, 200)
    }

    func testListViewDetected() {
        let root = collection(className: "android.widget.ListView", cellTops: [0, 100])
        let clusters = AndroidListDetector.detect(root: root)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].cellFrames.count, 2)
    }

    func testViewPagerNotDetected() {
        // Regression: ViewPager / ViewPager2 hold *pages*, not list
        // cells. Treating them as lists pollutes scope numbering with
        // one giant pseudo-list per pager (LINE's chat home has a
        // ViewPager wrapping the entire tab content).
        let root = collection(className: "androidx.viewpager2.widget.ViewPager2", cellTops: [0, 1000])
        XCTAssertEqual(AndroidListDetector.detect(root: root).count, 0)
    }

    func testCollectionInfoOnlyTriggersDetection() {
        // Container whose className isn't on the explicit list, but the
        // platform set `collectionInfo` — we still treat it as a list.
        let info = ElementNode.CollectionInfo(rowCount: 3, columnCount: 1, itemCount: 3, isHierarchical: false)
        let root = collection(className: "com.acme.CustomList", cellTops: [0, 100, 200], collectionInfo: info)
        XCTAssertEqual(AndroidListDetector.detect(root: root).count, 1)
    }

    func testSiblingListsRankedByArea() {
        // Two non-overlapping lists at different y bands — both
        // survive `dropNestedShadows`, ranked by area descending.
        let smallList = ElementNode(
            resourceId: "small", package: "test",
            className: "androidx.recyclerview.widget.RecyclerView",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 100, right: 200, bottom: 300),
            children: [leaf(width: 200, height: 50, top: 100), leaf(width: 200, height: 50, top: 150)]
        )
        let bigList = ElementNode(
            resourceId: "big", package: "test",
            className: "androidx.recyclerview.widget.RecyclerView",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 400, right: 1080, bottom: 900),
            children: [leaf(top: 400), leaf(top: 600), leaf(height: 100, top: 800)]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [smallList, bigList]
        )
        let clusters = AndroidListDetector.detect(root: root)
        XCTAssertEqual(clusters.count, 2)
        // Larger area first
        XCTAssertEqual(clusters[0].frame.width * clusters[0].frame.height,
                       clusters.map { $0.frame.width * $0.frame.height }.max())
    }

    func testEmptyAndSingleCellCollectionsDropped() {
        // Regression: a "list" with 0 or 1 cells is not a list. Empty
        // RecyclerViews surface on splash screens; single-cell wrappers
        // surface on every page of a ViewPager. Both used to consume
        // scope numbers and clutter the outline.
        let empty = collection(className: "androidx.recyclerview.widget.RecyclerView", cellTops: [])
        XCTAssertEqual(AndroidListDetector.detect(root: empty).count, 0)
        let single = collection(className: "androidx.recyclerview.widget.RecyclerView", cellTops: [0])
        XCTAssertEqual(AndroidListDetector.detect(root: single).count, 0)
    }

    func testNestedWrapperCollectionDropped() {
        // Regression: LINE-style "View(rowCount=1) > View(rowCount=1)
        // > View(rowCount=6, 4 cells)" produced three clusters in the
        // old detector — one per wrapper level — and the chat-list
        // alias ended up at `#1@6` because five shadow clusters
        // claimed scope 1–5 first. Now the innermost cluster wins.
        let info1 = ElementNode.CollectionInfo(rowCount: 1, columnCount: 1, itemCount: 1, isHierarchical: false)
        let info6 = ElementNode.CollectionInfo(rowCount: 6, columnCount: 1, itemCount: 6, isHierarchical: false)
        let chatList = ElementNode(
            resourceId: "", package: "test", className: "com.acme.View",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 274, right: 1080, bottom: 1055),
            collectionInfo: info6,
            children: [
                leaf(width: 1080, height: 179, top: 274),
                leaf(width: 1080, height: 179, top: 453),
                leaf(width: 1080, height: 179, top: 632),
                leaf(width: 1080, height: 179, top: 811),
            ]
        )
        let innerWrap = ElementNode(
            resourceId: "", package: "test", className: "com.acme.View",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 274, right: 1080, bottom: 2208),
            collectionInfo: info1,
            children: [chatList]
        )
        let outerWrap = ElementNode(
            resourceId: "", package: "test", className: "com.acme.View",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 274, right: 1080, bottom: 2208),
            collectionInfo: info1,
            children: [innerWrap]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [outerWrap]
        )
        let clusters = AndroidListDetector.detect(root: root)
        XCTAssertEqual(clusters.count, 1, "only the innermost real list should survive")
        XCTAssertEqual(clusters.first?.cellFrames.count, 4)
        XCTAssertEqual(clusters.first?.cellHeight, 179)
    }

    func testOffscreenViewPagerNeighbourDropped() {
        // Regression: a ViewPager renders left/right neighbour pages
        // at (x=-W, 0) and (x=+W, 0). Their internal RecyclerViews
        // would otherwise pollute the cluster list with no visible
        // cells.
        let info = ElementNode.CollectionInfo(rowCount: 5, columnCount: 1, itemCount: 5, isHierarchical: false)
        let offScreenLeft = ElementNode(
            resourceId: "", package: "test",
            className: "androidx.recyclerview.widget.RecyclerView",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: -1080, top: 274, right: 0, bottom: 2208),
            collectionInfo: info,
            children: [
                leaf(width: 1080, height: 179, top: 274),
                leaf(width: 1080, height: 179, top: 453),
            ]
        )
        let onScreen = ElementNode(
            resourceId: "", package: "test",
            className: "androidx.recyclerview.widget.RecyclerView",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 274, right: 1080, bottom: 800),
            children: [
                leaf(width: 1080, height: 179, top: 274),
                leaf(width: 1080, height: 179, top: 453),
            ]
        )
        let root = ElementNode(
            resourceId: "", package: "test", className: "android.widget.FrameLayout",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 2400),
            children: [offScreenLeft, onScreen]
        )
        let clusters = AndroidListDetector.detect(root: root)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertGreaterThanOrEqual(clusters.first?.frame.x ?? -1, 0)
    }

    func testContainerLabelSurfaces() {
        let root = collection(className: "android.widget.ListView", cellTops: [0, 50], contentDescription: "Friends list")
        let clusters = AndroidListDetector.detect(root: root)
        XCTAssertEqual(clusters[0].containerLabel, "Friends list")
    }

    /// `AccessibilityNodeInfo.isVisibleToUser()` reflects whether the
    /// platform actually drew the node. Recycled-but-still-attached
    /// cells (RecyclerView's view-recycling pool, ViewPager neighbour
    /// fragments mid-animation) can have positive bounds but
    /// `visibleToUser=false`. Counting them inflates `cellFrames.count`
    /// past the visible row count and skews the `#N@M` alias indices,
    /// because the renderer's pass-2 attribution filters by
    /// `visibleToUser` separately.
    func testVisibleToUserFiltersHiddenCells() {
        let hiddenCell = ElementNode(
            resourceId: "", package: "test", className: "android.view.View",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 200),
            visibleToUser: false
        )
        let visibleCell1 = ElementNode(
            resourceId: "", package: "test", className: "android.view.View",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 200, right: 1080, bottom: 400),
            visibleToUser: true
        )
        let visibleCell2 = ElementNode(
            resourceId: "", package: "test", className: "android.view.View",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 400, right: 1080, bottom: 600),
            visibleToUser: true
        )
        let list = ElementNode(
            resourceId: "", package: "test",
            className: "androidx.recyclerview.widget.RecyclerView",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 800),
            children: [hiddenCell, visibleCell1, visibleCell2]
        )
        let clusters = AndroidListDetector.detect(root: list)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(
            clusters.first?.cellFrames.count,
            2,
            "hidden cell must not contribute to cellFrames"
        )
    }

    /// A RecyclerView cell scrolled past the top of the container (the
    /// adapter has detached the row from layout but the platform has
    /// not yet recycled the node, so the node info still reports its
    /// stale negative-y bounds) should not count toward `cellFrames`.
    /// The container itself is on-screen; only the runaway cell isn't.
    func testCellOutsideContainerFrameDropped() {
        let stalentCell = ElementNode(
            resourceId: "", package: "test", className: "android.view.View",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: -500, right: 1080, bottom: -300)
        )
        let realCell1 = ElementNode(
            resourceId: "", package: "test", className: "android.view.View",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 200)
        )
        let realCell2 = ElementNode(
            resourceId: "", package: "test", className: "android.view.View",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 200, right: 1080, bottom: 400)
        )
        let list = ElementNode(
            resourceId: "", package: "test",
            className: "androidx.recyclerview.widget.RecyclerView",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 800),
            children: [stalentCell, realCell1, realCell2]
        )
        let clusters = AndroidListDetector.detect(root: list)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(
            clusters.first?.cellFrames.count,
            2,
            "stale cell whose frame is outside the container should not count"
        )
    }

    /// Median for an even-count list is the average of the two middle
    /// values, not the upper one. The current implementation returns
    /// `heights[n/2]` for even `n`, which is the upper element. With
    /// two disparate cells (100 and 200), the previous behaviour
    /// reported `cellHeight=200` (the bigger one), skewing the
    /// downstream "is this list scrollable?" heuristic. Use integer
    /// average for even `n` so the reported `cellHeight` is the
    /// statistical median, matching `iOS` convention.
    func testMedianHeightIsAverageForEvenCount() {
        let list = ElementNode(
            resourceId: "", package: "test",
            className: "androidx.recyclerview.widget.RecyclerView",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 800),
            children: [
                leaf(width: 1080, height: 100, top: 0),
                leaf(width: 1080, height: 200, top: 100),
            ]
        )
        let clusters = AndroidListDetector.detect(root: list)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters.first?.cellHeight, 150)
    }

    /// Odd-count median stays exact (regression guard for the even-n
    /// fix not breaking the common case).
    func testMedianHeightIsMiddleForOddCount() {
        let list = ElementNode(
            resourceId: "", package: "test",
            className: "androidx.recyclerview.widget.RecyclerView",
            text: "", contentDescription: "",
            boundsInScreen: .init(left: 0, top: 0, right: 1080, bottom: 800),
            children: [
                leaf(width: 1080, height: 100, top: 0),
                leaf(width: 1080, height: 180, top: 100),
                leaf(width: 1080, height: 300, top: 280),
            ]
        )
        let clusters = AndroidListDetector.detect(root: list)
        XCTAssertEqual(clusters.first?.cellHeight, 180)
    }
}