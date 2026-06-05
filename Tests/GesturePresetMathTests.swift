// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import SimUseCore
import XCTest

/// Unit tests for `GesturePreset.strokes()` / `coordinates()` — the
/// platform-agnostic coordinate math used by both the iOS HID path and
/// the Android bridge dispatch. Lives outside the E2E Playground suite
/// so it runs in plain `swift test` and guards refactors to the math.
final class GesturePresetMathTests: XCTestCase {

    // MARK: - Stroke-count invariants

    func testSingleFingerPresetsEmitOneStroke() {
        let single: [GesturePreset] = [
            .scrollUp, .scrollDown, .scrollLeft, .scrollRight,
            .swipeFromLeftEdge, .swipeFromRightEdge,
            .swipeFromTopEdge, .swipeFromBottomEdge,
        ]
        for preset in single {
            let strokes = preset.strokes(screenWidth: 1080, screenHeight: 2400)
            XCTAssertEqual(strokes.count, 1, "\(preset.rawValue) must emit one stroke")
            XCTAssertEqual(strokes[0].curve, .linear)
            XCTAssertFalse(preset.isMultiTouch, "\(preset.rawValue) must not be multi-touch")
        }
    }

    func testMultiTouchPresetsEmitTwoStrokes() {
        for preset in [GesturePreset.pinchIn, .pinchOut, .rotateCw, .rotateCcw] {
            let strokes = preset.strokes(screenWidth: 1080, screenHeight: 2400)
            XCTAssertEqual(strokes.count, 2, "\(preset.rawValue) must emit two strokes")
            XCTAssertTrue(preset.isMultiTouch, "\(preset.rawValue) must report isMultiTouch")
        }
    }

    // MARK: - Pinch geometry

    func testPinchOutEndpointsLandAtRadialPositions() {
        let strokes = GesturePreset.pinchOut.strokes(
            screenWidth: 1080, screenHeight: 2400,
            scale: 2.0,
            centerX: 200, centerY: 400,
            radius: 80
        )
        XCTAssertEqual(strokes.count, 2)
        let f1 = strokes[0]
        let f2 = strokes[1]
        // Finger 1 on the +x side: starts at (cx + r, cy), ends at (cx + r*s, cy).
        XCTAssertEqual(f1.startX, 280, accuracy: 1e-6)
        XCTAssertEqual(f1.startY, 400, accuracy: 1e-6)
        XCTAssertEqual(f1.endX, 360, accuracy: 1e-6)
        XCTAssertEqual(f1.endY, 400, accuracy: 1e-6)
        // Finger 2 on the -x side: starts at (cx - r, cy), ends at (cx - r*s, cy).
        XCTAssertEqual(f2.startX, 120, accuracy: 1e-6)
        XCTAssertEqual(f2.startY, 400, accuracy: 1e-6)
        XCTAssertEqual(f2.endX, 40, accuracy: 1e-6)
        XCTAssertEqual(f2.endY, 400, accuracy: 1e-6)
        XCTAssertEqual(f1.curve, .linear)
        XCTAssertEqual(f2.curve, .linear)
    }

    func testPinchInDefaultsToHalfScale() {
        let strokes = GesturePreset.pinchIn.strokes(
            screenWidth: 1080, screenHeight: 2400,
            centerX: 200, centerY: 400,
            radius: 80
        )
        let f1 = strokes[0]
        let f2 = strokes[1]
        // Default scale = 0.5 → endpoints at half the start radius.
        XCTAssertEqual(f1.startX, 280, accuracy: 1e-6)
        XCTAssertEqual(f1.endX, 240, accuracy: 1e-6)
        XCTAssertEqual(f2.startX, 120, accuracy: 1e-6)
        XCTAssertEqual(f2.endX, 160, accuracy: 1e-6)
    }

    // MARK: - Rotate geometry

    func testRotateArcWaypointsLandOnTheCircle() {
        let cx = 200.0, cy = 400.0, r = 80.0
        let strokes = GesturePreset.rotateCw.strokes(
            screenWidth: 1080, screenHeight: 2400,
            angle: 180,
            centerX: cx, centerY: cy,
            radius: r
        )
        let f1 = strokes[0]
        let f2 = strokes[1]
        for t in [0.0, 0.25, 0.5, 1.0] {
            let p1 = f1.point(at: t)
            let p2 = f2.point(at: t)
            let d1 = hypot(p1.x - cx, p1.y - cy)
            let d2 = hypot(p2.x - cx, p2.y - cy)
            XCTAssertEqual(d1, r, accuracy: 1e-6, "finger 1 @ t=\(t) must stay on the circle")
            XCTAssertEqual(d2, r, accuracy: 1e-6, "finger 2 @ t=\(t) must stay on the circle")
            // Two fingers stay diametrically opposite: midpoint == center.
            XCTAssertEqual((p1.x + p2.x) / 2, cx, accuracy: 1e-6)
            XCTAssertEqual((p1.y + p2.y) / 2, cy, accuracy: 1e-6)
            // …and the line connecting them passes through center: vectors
            // are anti-parallel of equal magnitude.
            XCTAssertEqual(p1.x - cx, -(p2.x - cx), accuracy: 1e-6)
            XCTAssertEqual(p1.y - cy, -(p2.y - cy), accuracy: 1e-6)
        }
    }

    func testRotateCwAndCcwSweepInOppositeDirections() {
        let strokes_cw = GesturePreset.rotateCw.strokes(
            screenWidth: 1080, screenHeight: 2400,
            angle: 90,
            centerX: 200, centerY: 400,
            radius: 80
        )
        let strokes_ccw = GesturePreset.rotateCcw.strokes(
            screenWidth: 1080, screenHeight: 2400,
            angle: 90,
            centerX: 200, centerY: 400,
            radius: 80
        )
        // Halfway through, the cw and ccw fingers should sit on opposite
        // sides of the diameter through the start positions.
        let cwMid = strokes_cw[0].point(at: 0.5)
        let ccwMid = strokes_ccw[0].point(at: 0.5)
        XCTAssertEqual(cwMid.x, ccwMid.x, accuracy: 1e-6, "cw / ccw share the same x at the same |angle|")
        XCTAssertEqual(cwMid.y, -ccwMid.y + 2 * 400, accuracy: 1e-6, "cw / ccw mirror across y=cy")
    }

    // MARK: - coordinates() compatibility shim

    func testCoordinatesMatchFirstStrokeForSinglePresets() {
        for preset in [
            GesturePreset.scrollUp, .scrollDown, .scrollLeft, .scrollRight,
            .swipeFromLeftEdge, .swipeFromRightEdge,
            .swipeFromTopEdge, .swipeFromBottomEdge,
        ] {
            let s = preset.strokes(screenWidth: 1080, screenHeight: 2400)[0]
            let c = preset.coordinates(screenWidth: 1080, screenHeight: 2400)
            XCTAssertEqual(c.startX, s.startX)
            XCTAssertEqual(c.startY, s.startY)
            XCTAssertEqual(c.endX, s.endX)
            XCTAssertEqual(c.endY, s.endY)
        }
    }

    // MARK: - Default flag accessors

    func testDefaultScaleAngleRadiusByPreset() {
        XCTAssertEqual(GesturePreset.pinchOut.defaultScale, 2.0)
        XCTAssertEqual(GesturePreset.pinchIn.defaultScale, 0.5)
        XCTAssertNil(GesturePreset.scrollUp.defaultScale)
        XCTAssertEqual(GesturePreset.rotateCw.defaultAngle, 90.0)
        XCTAssertEqual(GesturePreset.rotateCcw.defaultAngle, 90.0)
        XCTAssertNil(GesturePreset.pinchIn.defaultAngle)
        XCTAssertEqual(GesturePreset.pinchOut.defaultRadius, 80.0)
        XCTAssertEqual(GesturePreset.rotateCw.defaultRadius, 80.0)
        XCTAssertNil(GesturePreset.scrollUp.defaultRadius)
    }

    // MARK: - MultiTouchOptions placement rules

    func testFingerTwoPointDefaultsToFingerDistanceOnXAxis() throws {
        let opts = try MultiTouchOptions.parse(["--fingers", "2", "--finger-distance", "75"])
        let p2 = opts.fingerTwoPoint(forFinger1: (x: 100, y: 200))
        XCTAssertEqual(p2.x, 175, accuracy: 1e-6)
        XCTAssertEqual(p2.y, 200, accuracy: 1e-6)
    }

    func testFingerTwoPointUsesExplicitCoordinatesWhenSupplied() throws {
        let opts = try MultiTouchOptions.parse([
            "--fingers", "2",
            "--x2", "500",
            "--y2", "600",
            "--finger-distance", "75",  // should be ignored when x2/y2 set
        ])
        let p2 = opts.fingerTwoPoint(forFinger1: (x: 100, y: 200))
        XCTAssertEqual(p2.x, 500, accuracy: 1e-6)
        XCTAssertEqual(p2.y, 600, accuracy: 1e-6)
    }

    func testMultiTouchOptionsRejectsAsymmetricX2Y2() {
        XCTAssertThrowsError(try MultiTouchOptions.parse(["--fingers", "2", "--x2", "500"]))
    }

    func testMultiTouchOptionsRejectsThreeFingers() {
        XCTAssertThrowsError(try MultiTouchOptions.parse(["--fingers", "3"]))
    }

    // MARK: - Scroll presets: center-of-screen, scroll distance ≈ ¼ of axis

    func testScrollUpCentersHorizontallyAndMovesUpward() {
        let coords = GesturePreset.scrollUp.coordinates(screenWidth: 1080, screenHeight: 2400)
        XCTAssertEqual(coords.startX, 540, accuracy: 0.01)
        XCTAssertEqual(coords.endX, 540, accuracy: 0.01)
        // scroll-distance = screenHeight / 4 = 600 → split half above / half below center.
        // Scroll-up = finger goes from below-center to above-center.
        XCTAssertEqual(coords.startY, 1500, accuracy: 0.01)   // 1200 + 300
        XCTAssertEqual(coords.endY, 900, accuracy: 0.01)      // 1200 - 300
    }

    func testScrollDownIsScrollUpReversed() {
        let up = GesturePreset.scrollUp.coordinates(screenWidth: 1080, screenHeight: 2400)
        let down = GesturePreset.scrollDown.coordinates(screenWidth: 1080, screenHeight: 2400)
        XCTAssertEqual(up.startX, down.startX)
        XCTAssertEqual(up.endX, down.endX)
        // Swapping start/end Y between the two presets.
        XCTAssertEqual(up.startY, down.endY)
        XCTAssertEqual(up.endY, down.startY)
    }

    func testScrollLeftMovesAlongHorizontalAxis() {
        let coords = GesturePreset.scrollLeft.coordinates(screenWidth: 1080, screenHeight: 2400)
        XCTAssertEqual(coords.startY, 1200, accuracy: 0.01)
        XCTAssertEqual(coords.endY, 1200, accuracy: 0.01)
        // scroll-distance = screenWidth / 4 = 270 → split half each side of center.
        XCTAssertEqual(coords.startX, 675, accuracy: 0.01)    // 540 + 135
        XCTAssertEqual(coords.endX, 405, accuracy: 0.01)      // 540 - 135
    }

    /// On an iPhone-15-shaped screen (390×844, the old default), the new
    /// formula still lands ~¼ of the screen — close enough to the prior
    /// hard-coded 200 px that existing iOS behaviour is unchanged in
    /// practice (≈211 vs 200).
    func testScrollDistanceOnTinyIosScreenStaysCloseToOldDefault() {
        let coords = GesturePreset.scrollUp.coordinates(screenWidth: 390, screenHeight: 844)
        let distance = coords.startY - coords.endY
        XCTAssertEqual(distance, 211, accuracy: 1.0,
                       "iPhone-15 default scroll should stay near 200 px; got \(distance)")
    }

    // MARK: - Edge swipes: edgeMargin=20, terminate at opposite edge - 20

    func testSwipeFromLeftEdgeSpansHorizontalAxis() {
        let coords = GesturePreset.swipeFromLeftEdge.coordinates(screenWidth: 1080, screenHeight: 2400)
        XCTAssertEqual(coords.startX, 20, accuracy: 0.01)
        XCTAssertEqual(coords.endX, 1060, accuracy: 0.01) // width - edgeMargin
        XCTAssertEqual(coords.startY, 1200, accuracy: 0.01)
        XCTAssertEqual(coords.endY, 1200, accuracy: 0.01)
    }

    func testSwipeFromRightEdgeIsLeftEdgeReversed() {
        let left = GesturePreset.swipeFromLeftEdge.coordinates(screenWidth: 1080, screenHeight: 2400)
        let right = GesturePreset.swipeFromRightEdge.coordinates(screenWidth: 1080, screenHeight: 2400)
        XCTAssertEqual(left.startX, right.endX)
        XCTAssertEqual(left.endX, right.startX)
        XCTAssertEqual(left.startY, right.startY)
    }

    func testSwipeFromTopEdgeSpansVerticalAxis() {
        let coords = GesturePreset.swipeFromTopEdge.coordinates(screenWidth: 1080, screenHeight: 2400)
        XCTAssertEqual(coords.startY, 20, accuracy: 0.01)
        XCTAssertEqual(coords.endY, 2380, accuracy: 0.01) // height - edgeMargin
        XCTAssertEqual(coords.startX, 540, accuracy: 0.01) // horizontal center
        XCTAssertEqual(coords.endX, 540, accuracy: 0.01)
    }

    // MARK: - Default duration / delta (used as Android fallback when --duration/--delta omitted)

    // MARK: - recommendedRadius — display-aware adaptive default

    func testRecommendedRadiusOnTypicalIosScreenSticksAtFloor() {
        // 390x844 (iPhone 15 baseline): 0.15 * 390 = 58.5 → floored to 80.
        XCTAssertEqual(GesturePreset.recommendedRadius(screenWidth: 390, screenHeight: 844), 80, accuracy: 1e-6)
        // 402x874 (iPhone 17 Pro): 0.15 * 402 = 60.3 → floored to 80.
        XCTAssertEqual(GesturePreset.recommendedRadius(screenWidth: 402, screenHeight: 874), 80, accuracy: 1e-6)
    }

    func testRecommendedRadiusOnAndroidScalesUp() {
        // 1080x2400 (Pixel-class emulator): 0.15 * 1080 = 162.
        XCTAssertEqual(GesturePreset.recommendedRadius(screenWidth: 1080, screenHeight: 2400), 162, accuracy: 1e-6)
        // 1440x3120 (S22 Ultra-class): 0.15 * 1440 = 216.
        XCTAssertEqual(GesturePreset.recommendedRadius(screenWidth: 1440, screenHeight: 3120), 216, accuracy: 1e-6)
    }

    func testRecommendedRadiusKeepsScale3WithinScreen() {
        // The 15% factor must leave headroom for `--scale 3.0` without
        // tipping endpoints across the display edge — that's the rule
        // the inline comment promises.
        let r = GesturePreset.recommendedRadius(screenWidth: 1080, screenHeight: 2400)
        let maxExcursion = r * 3.0
        XCTAssertLessThan(maxExcursion, 1080 / 2, "scale=3 from screen centre must stay on-screen")
    }

    func testStrokesUseRecommendedRadiusWhenOmitted() {
        // No explicit `radius` → strokes() picks recommendedRadius for the
        // resolved screen size. Pinch-out on 1080x2400 → 162 base.
        let strokes = GesturePreset.pinchOut.strokes(
            screenWidth: 1080, screenHeight: 2400,
            scale: 2.0,
            centerX: 540, centerY: 1200,
            radius: nil
        )
        // Finger 1 starts at (cx + r, cy) = (540 + 162, 1200) = (702, 1200).
        XCTAssertEqual(strokes[0].startX, 702, accuracy: 1e-6)
        XCTAssertEqual(strokes[0].startY, 1200, accuracy: 1e-6)
        // End at (cx + r*s, cy) = (540 + 324, 1200) = (864, 1200).
        XCTAssertEqual(strokes[0].endX, 864, accuracy: 1e-6)
    }

    // MARK: - recommendedDuration — angle-aware adaptive default

    func testRecommendedDurationForRotateScalesLinearlyWithAngle() {
        XCTAssertEqual(GesturePreset.rotateCw.recommendedDuration(angle: 90), 0.5, accuracy: 1e-9)
        XCTAssertEqual(GesturePreset.rotateCw.recommendedDuration(angle: 180), 1.0, accuracy: 1e-9)
        XCTAssertEqual(GesturePreset.rotateCw.recommendedDuration(angle: 270), 1.5, accuracy: 1e-9)
        XCTAssertEqual(GesturePreset.rotateCw.recommendedDuration(angle: 360), 2.0, accuracy: 1e-9)
        // CCW direction must follow the same rule.
        XCTAssertEqual(GesturePreset.rotateCcw.recommendedDuration(angle: 270), 1.5, accuracy: 1e-9)
        // Magnitude: negative angle still extends.
        XCTAssertEqual(GesturePreset.rotateCw.recommendedDuration(angle: -270), 1.5, accuracy: 1e-9)
    }

    func testRecommendedDurationForRotateAtNilDefaultsTo90() {
        // angle: nil → defaultAngle (90) → 0.5s (matches baseline, no extension).
        XCTAssertEqual(GesturePreset.rotateCw.recommendedDuration(angle: nil), 0.5, accuracy: 1e-9)
    }

    func testRecommendedDurationForRotateBelowFloorReturnsBaseline() {
        // Small angles must not shrink below the 0.5s baseline.
        XCTAssertEqual(GesturePreset.rotateCw.recommendedDuration(angle: 30), 0.5, accuracy: 1e-9)
    }

    func testRecommendedDurationForNonRotatePresetsIgnoresAngle() {
        // Pinch / scroll / edge presets stay on `defaultDuration`
        // regardless of the angle argument (which doesn't even apply
        // to them).
        XCTAssertEqual(GesturePreset.pinchIn.recommendedDuration(angle: 270), 0.5, accuracy: 1e-9)
        XCTAssertEqual(GesturePreset.pinchOut.recommendedDuration(angle: 360), 0.5, accuracy: 1e-9)
        XCTAssertEqual(GesturePreset.scrollUp.recommendedDuration(angle: 1000), 0.5, accuracy: 1e-9)
        XCTAssertEqual(GesturePreset.swipeFromLeftEdge.recommendedDuration(angle: 1000), 0.3, accuracy: 1e-9)
    }

    func testScrollPresetsDefaultToHalfSecond() {
        for preset in [GesturePreset.scrollUp, .scrollDown, .scrollLeft, .scrollRight] {
            XCTAssertEqual(preset.defaultDuration, 0.5, "scroll presets share 0.5s default")
        }
    }

    func testEdgePresetsDefaultToFasterSwipe() {
        for preset in [
            GesturePreset.swipeFromLeftEdge,
            .swipeFromRightEdge,
            .swipeFromTopEdge,
            .swipeFromBottomEdge,
        ] {
            XCTAssertEqual(preset.defaultDuration, 0.3, "edge presets share 0.3s default")
        }
    }
}